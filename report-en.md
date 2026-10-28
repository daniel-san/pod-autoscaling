# Near scale-to-zero on OKE: keep one warm pod, make it tiny

Research report, 27 October 2026. Portuguese version: [report-pt-BR.md](report-pt-BR.md).

Scope: how to get most of the savings of scale-to-zero on Oracle Kubernetes Engine (OKE) without paying the cold-start penalty. It covers vertical scaling of the remaining pod, the OKE and Kubernetes features that already help, and whether cutting CPU or memory saves more.

All manifests referenced here are in [`examples/`](examples/). The behaviour claims marked **(lab)** were checked on a local Kubernetes 1.36.4 cluster with [`lab/run-lab.sh`](lab/run-lab.sh). Cost figures come from [`lab/cost-model.py`](lab/cost-model.py) and OCI's public price list.

---

## 1. Summary

1. **Savings come from requests, not usage.** On OKE managed nodes you pay for whole worker nodes. The scheduler places pods by their resource *requests*, and the node autoscaler removes a node only when the requests on it allow it. Shrinking a pod saves money only if smaller requests lead to fewer or cheaper nodes.
2. **One warm, CPU-trimmed pod gets about 90% of the scale-to-zero saving.** In the cost model (30 services, 3 replicas in business hours), true scale-to-zero at night saves 64%. Keeping 1 replica per service with its CPU request cut to 50m saves 58%. The warm pod costs about US$1.40 per service per month (E5 Flex, pay-as-you-go).
3. **Vertical scaling without restarts is ready on OKE.** In-place pod resize is GA since Kubernetes 1.35. OKE currently supports 1.34.10, 1.35.2 and 1.36.4 (1.37.0 in preview). VPA 1.6+ can apply recommendations in place (`InPlaceOrRecreate`), and VPA 1.7+ adds an alpha CPU Startup Boost.
4. **Cut CPU first, memory carefully.**
   - On E5/E6 Flex, 1 vCPU costs the same as 7.5 GB of RAM, so CPU is about 78% of the cost of a typical 500m/1Gi pod.
   - CPU is compressible: a starved container slows down, nobody kills it. Idle CPU usage also really drops to a few millicores.
   - Memory is not compressible. Exceeding the memory *limit* gets the container OOM-killed. Using more than the memory *request* puts the pod first in line for eviction when the node runs short.
   - Idle memory usage barely drops unless the application returns memory to the OS.
   - Rule: lower CPU requests hard. Lower memory *requests* only down to the measured idle working set. Never lower memory *limits* below current usage.
5. **Recommended stack:**
   - KEDA (or HPA) with `minReplicas: 1` on an absolute CPU or request-rate target.
   - VPA in `Off` mode to measure, then `InPlaceOrRecreate` with `RequestsOnly`, or a schedule-based in-place shrinker for predictable off-hours.
   - A CPU startup boost to keep cold starts short.
   - Cluster Autoscaler (OKE add-on) or Karpenter Provider for OCI to turn the freed requests into fewer nodes. Burstable nodes for low-CPU pools. Preemptible nodes only for extra replicas.
6. **Avoid:**
   - Virtual nodes for tiny warm pods. Allocation rounds up to whole OCPUs and GBs, so a 50m pod costs about 10x more there.
   - HPA on CPU *Utilization* together with shrinking requests. Utilization is usage divided by request, so shrinking the request causes a scale-out storm.
   - Two controllers changing the same pod's resources.
   - Putting the only warm replica on preemptible capacity.

---

## 2. Context and assumptions

- **OKE versions (Oct 2026):** 1.34.10, 1.35.2, 1.36.4, plus 1.37.0 as a preview ([OKE release notes](https://docs.oracle.com/iaas/releasenotes/services/conteng/)). In-place resize needs 1.33+ and is GA from 1.35. Kubernetes 1.35+ requires cgroup v2, which OKE OL8 images provide ([OKE 1.35 blog](https://blogs.oracle.com/cloud-infrastructure/oke-welcomes-kubernetes-1-35)).
- **Cluster type:** I assume *enhanced* clusters (US$0.10/h per cluster). The managed add-ons (Cluster Autoscaler, Metrics Server), virtual nodes, workload identity and self-managed nodes all require them ([basic vs enhanced](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcomparingenhancedwithbasicclusters_topic.htm)).
- **Prices:** OCI public price list API, pay-as-you-go USD, fetched 2026-10-27. Negotiated discounts change the absolute numbers, not the ratios.
- **Cost model simplification:** cost is attributed to requested resources. This assumes nodes are well packed and the node autoscaler removes capacity. Real savings are lower by your packing inefficiency.
- **Lab:** kind v0.33 with Kubernetes 1.36.4 on containerd 2.3.4, VPA 1.8.1, KEDA 2.21.0, metrics-server 0.9.0. OKE uses CRI-O instead of containerd, and the lab cannot test OCI node provisioning, so only pod-level behaviour was verified.

---

## 3. How the money flows on OKE

Three layers decide the bill. "Near zero" means working all three.

| Layer | What changes | Tools | Saves money when |
|---|---|---|---|
| Replicas (horizontal) | Number of pods | HPA, KEDA | Fewer pods means fewer requests |
| Pod size (vertical) | Requests/limits per pod | In-place resize, VPA, startup boost, shrinker | Smaller requests |
| Capacity (nodes) | Number, shape and price of nodes | Cluster Autoscaler, Karpenter (KPO), flex/burstable/preemptible/Arm shapes | Nodes are removed or replaced by cheaper ones |

The first two layers only lower *requests*. The third layer is where requests become money. If no node goes away, shrinking pods saves nothing.

---

## 4. What OKE and Kubernetes already provide

| Feature | Status on OKE (Oct 2026) | Role in "near zero" | Notes |
|---|---|---|---|
| In-place pod resize | GA on OKE 1.35.2 / 1.36.4; beta and on by default on 1.34.10 | Shrink and grow running pods without restart | CPU and memory only; QoS class cannot change |
| Vertical Pod Autoscaler | You install it (Helm chart or upstream script). [OKE guide](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengusingverticalpodautoscaler.htm) | Measure and right-size requests | Not supported on virtual nodes. The OKE guide still uses VPA 0.8 and the deprecated `Auto` mode; use VPA 1.8.x |
| HPA | Native | Keep `minReplicas: 1`, scale on load | Use `AverageValue`, not `Utilization`, when requests change |
| HPA scale to zero | Beta in K8s 1.37 ([blog](https://kubernetes.io/blog/2026/09/02/kubernetes-v1-37-hpa-scale-to-zero-beta/)) | True zero for non-prod | OKE has 1.37 only as a preview |
| Metrics Server | OKE add-on | Needed by HPA and VPA | |
| Cluster Autoscaler | OKE add-on or standalone ([docs](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengusingclusterautoscaler.htm)) | Removes nodes after requests drop; pools can go to 0 | One shape per node pool; keep a system pool it does not manage |
| Karpenter Provider for OCI (KPO) | GA April 2026, v1.4.0 ([docs](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/conteng-kpo.htm), [GA blog](https://blogs.oracle.com/cloud-infrastructure/smarter-kubernetes-autoscaling-with-karpenter)) | Consolidates under-used nodes, picks shapes, supports burstable and preemptible | Supports K8s 1.31 to 1.36 |
| Flexible shapes | Managed and KPO nodes | Pick the OCPU:memory ratio that matches your requests | 1 to 64 GB per OCPU on E4/E5 |
| Burstable instances | KPO (`baselineOcpuUtilization`) and self-managed nodes | Pay for 12.5% or 50% of the OCPUs | Memory is billed in full; bursts last at most about 1 h ([docs](https://docs.oracle.com/en-us/iaas/Content/Compute/References/burstable-instances.htm)) |
| Preemptible capacity | Managed node pools and KPO | 50% cheaper nodes | Reclaimed at any time, about 2 min notice; cannot be burstable ([docs](https://docs.oracle.com/en-us/iaas/Content/Compute/Concepts/preemptible.htm)) |
| Ampere A1/A2 (Arm) | Managed and KPO nodes | Cheaper CPU | Needs multi-arch images |
| Virtual nodes | Enhanced clusters | Serverless burst capacity | Poor fit for tiny pods (section 8.4) |

I found no field for the burstable baseline in the OKE managed node pool API: its `NodeShapeConfig` only exposes `ocpus` and `memoryInGBs`. Burstable workers therefore come through KPO or self-managed nodes.

**Open-source tools around this:**

| Tool | Version checked | Use |
|---|---|---|
| [KEDA](https://keda.sh) | 2.21.0 | Cron and event triggers; can keep `minReplicaCount: 1`. Oracle shows KEDA plus the Cluster Autoscaler on OKE in [this blog](https://blogs.oracle.com/cloud-infrastructure/optimizing-oke-costs-with-keda-and-cluster-autoscaling) |
| KEDA HTTP add-on | 0.16.0 (beta) | Holds requests while a service scales from zero. Fits non-prod only, since it still waits for the cold start |
| [kube-startup-cpu-boost](https://github.com/google/kube-startup-cpu-boost) | 0.21.3 | Temporary CPU boost at start-up via in-place resize |
| [Goldilocks](https://github.com/FairwindsOps/goldilocks) | 4.16.2 | Dashboard over VPA recommendations |
| [KRR](https://github.com/robusta-dev/krr) | 1.31.1 | Request recommendations from Prometheus history, no VPA needed |
| [OpenCost](https://www.opencost.io/docs/configuration/oracle) | 1.121.3 | Per-namespace and per-workload cost; supports OCI pricing |
| [GoKubeDownscaler](https://github.com/caas-team/GoKubeDownscaler) / kube-green | 1.4.2 / 0.7.1 | Office-hours scale-to-zero for non-prod |
| [Elastic CPU Pod Autoscaler (DoorDash)](https://github.com/doordash-oss/elastic-cpu-pod-autoscaler) | n/a | Fast, CPU-only in-place autoscaling |

Commercial products also implement the "shrink the last replica" idea directly. One example is Kedify's [PodResourceProfile](https://docs.kedify.io/how-to/prp-shrink-pod-instead-of-scale-to-zero/), which resizes requests in place when a KEDA ScaledObject turns inactive. CAST AI, ScaleOps and others offer in-place rightsizing too. I did not evaluate them.

---

## 5. Vertical scaling on OKE

### 5.1 In-place pod resize: the mechanism

You change `spec.containers[*].resources` through the pod's `resize` subresource, and the kubelet applies the new values to the running container's cgroup ([Kubernetes docs](https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/)).

```bash
kubectl -n demo patch pod my-app-xxxx --subresource resize \
  -p '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"25m","memory":"64Mi"}}}]}}'
```

| Value | Linux cgroup v2 effect | Effect of lowering it |
|---|---|---|
| CPU request | `cpu.weight` (share under contention) | Less CPU only when the node is busy; scheduler sees more free room |
| CPU limit | `cpu.max` (hard quota) | Throttling above the new limit |
| Memory request | Scheduling and eviction ranking only (unless the `MemoryQoS` feature gate is enabled) | Scheduler sees more free room; pod moves up the eviction queue if usage > request |
| Memory limit | `memory.max` | OOM kill if usage exceeds it |

Rules that matter for this pattern:

- **The QoS class cannot change.** A Guaranteed pod (requests = limits) can only be resized with requests still equal to limits. To lower requests while keeping limits, the pod must be Burstable from the start ([`examples/01-app-deployment.yaml`](examples/01-app-deployment.yaml)).
- **`resizePolicy`** per resource is `NotRequired` (default, no restart) or `RestartContainer`.
- **Memory limit decreases are best effort.** If current usage is above the new limit, the kubelet holds the resize as "in progress" and does not apply it.
- **Use strategic merge patch (the kubectl default) or JSON patch.** `--type merge` replaces the whole containers list, and the API server rejects the request. **(lab)**
- **The Deployment template is not changed.** New pods (scale-out, rescheduling after a node drain) start at template size. GitOps tools see no drift.
- RBAC for automation needs `get` and `patch` on `pods/resize`. **(lab)**
- Kubernetes 1.36 adds beta in-place resize of pod-level resources (`spec.resources`), which helps multi-container pods ([blog](https://kubernetes.io/blog/2026/04/30/kubernetes-v1-36-inplace-pod-level-resources-beta/)).

**Lab results (Kubernetes 1.36.4):**

| Test | Result |
|---|---|
| Requests 500m/256Mi → 25m/64Mi, limits unchanged | Applied, `restartCount` 0. `cpu.weight` went from 59 to 6; `cpu.max` and `memory.max` unchanged |
| Lower requests to equal limits (Burstable → Guaranteed) | Rejected: "Pod QOS Class may not change as a result of resizing" |
| Memory request 64Mi on a container using ~200Mi | Applied, no restart |
| Memory limit 400Mi → 128Mi on a container using ~200Mi | Not applied; condition `PodResizeInProgress`; actual limit stayed 400Mi |
| Memory limit 400Mi → 300Mi (above usage) | Applied, no restart |
| Raise requests back to 500m/256Mi | Applied, no restart |

One more lab observation: after lowering the memory request, the container's `oom_score_adj` stayed at the value computed from the original request. Do not count on a smaller request making the pod a more likely kernel OOM victim; the kubelet's eviction ranking does use the current request.

### 5.2 Vertical Pod Autoscaler

**Install on OKE** with the official Helm chart instead of the 0.8-era script in the OKE guide:

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade --install vpa autoscaler/vertical-pod-autoscaler --version 0.15.0 -n kube-system
# Metrics: enable the OKE "Kubernetes Metrics Server" cluster add-on first.
```

**Update modes in VPA 1.8** ([API reference](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/api.md)):

| Mode | Behaviour | Use it for |
|---|---|---|
| `Off` | Recommends only | Always start here ([`02`](examples/02-vpa-recommend-only.yaml)) |
| `Initial` | Sets requests at pod creation only | Combining with another controller that resizes later |
| `Recreate` | Evicts pods to apply changes | Legacy; `Auto` is deprecated and means the same |
| `InPlaceOrRecreate` | Resizes in place, evicts only if that fails | Default choice (GA since VPA 1.6) ([`03`](examples/03-vpa-inplace.yaml)) |
| `InPlace` | Resizes in place, never evicts | Alpha (VPA 1.7, `--feature-gates=InPlace=true`) |

Recommended policy for this use case (from [`examples/03-vpa-inplace.yaml`](examples/03-vpa-inplace.yaml)):

```yaml
spec:
  updatePolicy:
    updateMode: "InPlaceOrRecreate"
    minReplicas: 1                     # allow updates on single-replica workloads
  resourcePolicy:
    containerPolicies:
      - containerName: app
        controlledValues: RequestsOnly # keep limits as written
        minAllowed: { cpu: 25m, memory: 128Mi }
        maxAllowed: { cpu: "2", memory: 2Gi }
```

`RequestsOnly` keeps the memory limit as a fixed safety ceiling. It also keeps the CPU limit, which the JVM and other runtimes read at start-up to size their thread pools.

**What VPA is and is not good at.** The recommender keeps an 8-day, exponentially decaying usage histogram ([flags](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/flags.md)):

- CPU target is the 90th percentile of usage.
- Memory target is the 90th percentile of daily *peaks*.
- 15% safety margin on top of both.
- Floors of 25m CPU and 250 MB memory per pod.

So VPA sizes a pod for its busy day. It does not shrink it for the night. Treat VPA as the right-sizing tool and use a separate mechanism (5.4) for idle periods.

**Lab results:**
- With the upstream "hamster" workload (requests 100m, burns about 500m), `InPlaceOrRecreate` raised the request to 587m within about two minutes on the same pod, with zero restarts.
- VPA also raised the memory request from 50Mi to 250Mi because of the 250 MB default floor. For very small pods, lower `--pod-recommendation-min-memory-mb` on the recommender.

### 5.3 CPU startup boost: small steady state, fast start

A small CPU request slows down start-up when the node is busy, and a low CPU limit slows it down every time. JIT-compiled runtimes suffer most. A startup boost gives the pod more CPU until it is Ready, then shrinks it in place. That makes a tiny steady-state request compatible with short cold starts, and it also speeds up scale-out from 1 replica.

| Option | Status | Example |
|---|---|---|
| VPA `startupBoost` | Alpha, VPA 1.7+, gate `CPUStartupBoost` on admission controller and updater | [`04-vpa-startup-boost.yaml`](examples/04-vpa-startup-boost.yaml) |
| kube-startup-cpu-boost operator | v0.21.3, independent of VPA | [`10-kube-startup-cpu-boost.yaml`](examples/10-kube-startup-cpu-boost.yaml) |

**Lab results:**
- VPA boost with factor 4: the CPU request went from 500m to 999m at creation. `RequestsOnly` caps the boost just below the 1-CPU limit to keep the QoS class. 30 s after Ready, VPA resized the pod in place to its recommendation (25m), with zero restarts.
- kube-startup-cpu-boost applied the boost at admission and reverted it 3 s later, when the pod became Ready.

Caveats ([kube-startup-cpu-boost README](https://github.com/google/kube-startup-cpu-boost)):

- If the boost raises the CPU *limit*, a JVM sizes its pools for the boosted CPU count and keeps them after the revert. Keep boosts modest or set `-XX:ActiveProcessorCount`.
- A boosted request can trigger a node scale-up that is useless a minute later. Keep some headroom or slow down scale-down.

### 5.4 Shrinking the warm pod during idle periods

Two ways to do it:

**a) Schedule-based (predictable office hours).** [`examples/05-idle-shrinker-cronjob.yaml`](examples/05-idle-shrinker-cronjob.yaml) is a small, dependency-free implementation:

- At 20:00 Mon–Fri, a CronJob lowers the requests of opted-in pods to the values in their `idle-shrink.example.com/requests` annotation.
- At 07:30, a second CronJob restores the requests from the owning ReplicaSet template.
- Limits are never touched.
- Memory guard: the job never sets a memory request below current usage + 15%. If metrics are missing, it leaves memory alone.

Lab: shrink and restore both worked with zero restarts. The memory guard raised a 32Mi idle target to 230Mi for a container using 200Mi.

**b) Event-based (unpredictable traffic).** Shrink when the ScaledObject goes inactive and grow on activation. There is no mature open-source controller for this yet. Kedify PodResourceProfile does it commercially, and DoorDash's EPCAS covers the CPU-only case. Alternatively, keep the warm pod at a "small but responsive" size (for example 100m CPU) and let the HPA add full-size pods.

Do not combine (a) with VPA in `InPlaceOrRecreate`, `Recreate` or `InPlace` mode on the same workload, because VPA reverts the change. VPA `Off` or `Initial` is fine.

### 5.5 Interaction rules

| Combination | Safe? | Why |
|---|---|---|
| HPA/KEDA on CPU `Utilization` + any request shrinking | No | Example: request 500m with a 70% target scales out at 350m. After shrinking to 25m, it scales out at 17.5m |
| HPA/KEDA on CPU `AverageValue`, request rate, or queue length + VPA/shrinker | Yes | Signal does not depend on requests ([`06`](examples/06-keda-cron-min-one.yaml), [`07`](examples/07-hpa-absolute-cpu.yaml)) |
| VPA (updating) + HPA on the same CPU/memory metric | No | Upstream VPA and OKE both advise against it |
| VPA (updating) + idle shrinker on the same pods | No | Two writers fight |
| VPA startupBoost + kube-startup-cpu-boost on the same pods | No | Pick one |
| VPA (updating) + KEDA cron with `minReplicaCount: 1` | Yes | Different layers |

---

## 6. CPU or memory: which reduction saves more?

### 6.1 Price per unit

Kubernetes `1` CPU = 1 vCPU. On x86 shapes, 1 OCPU = 2 vCPUs. On Ampere A1, 1 OCPU = 1 vCPU. On A2, 1 OCPU = 2 cores.

| Shape | USD per vCPU-hour | USD per GB-hour | GB of RAM that cost as much as 1 vCPU |
|---|---|---|---|
| E4 Flex (AMD) | 0.0125 | 0.0015 | 8.3 |
| E5 Flex (AMD) | 0.0150 | 0.0020 | 7.5 |
| E6 Flex (AMD) | 0.0150 | 0.0020 | 7.5 |
| A1 Flex (Ampere) | 0.0100 | 0.0015 | 6.7 |
| A2 Flex (AmpereOne) | 0.0070 | 0.0020 | 3.5 |

Typical services request 1 to 4 GB per vCPU, far below these break-even ratios. CPU is the bigger part of the bill unless a pod requests more than about 7 GB per vCPU on AMD shapes.

### 6.2 Where the money goes in one pod (E5 Flex, 24x7)

| Requests | CPU USD/month | Memory USD/month | CPU share |
|---|---|---|---|
| 1000m / 2Gi | 10.95 | 3.14 | 78% |
| 500m / 1Gi | 5.47 | 1.57 | 78% |
| 250m / 1Gi | 2.74 | 1.57 | 64% |
| 50m / 1Gi | 0.55 | 1.57 | 26% |

Once CPU is trimmed, memory becomes most of what is left. Memory is also the resource you can only reduce further by changing the application (6.4).

### 6.3 What happens when each one is too low

**CPU too low:**

- Below the request, nothing happens. Under contention a container gets CPU in proportion to its request, and spare CPU is shared.
- At the limit, the kernel throttles the container: latency goes up, and nothing is killed.
- Indirect risk: a liveness probe that times out under throttling restarts the container. Give probes generous timeouts and do not run heavy work inside them.

**Memory too low.** Three separate mechanisms can kill or move a pod ([node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)):

| Mechanism | Trigger | Result | Controlled by |
|---|---|---|---|
| Container OOM kill | Container usage > its memory **limit** | Kernel kills the process; kubelet restarts the container (cold start) | Memory limit |
| Kubelet eviction | Node memory available falls below the eviction threshold | Pod deleted and recreated elsewhere (cold start). Pods whose usage exceeds their **request** go first, then by priority, then by how far over request they are | Memory request, PriorityClass |
| Node OOM | Node runs out before the kubelet reacts | Kernel kills by `oom_score_adj`: BestEffort 1000, Burstable 2–999 (smaller request = higher score), Guaranteed −997 | QoS class, request |

So the concern that pods get killed when memory is too low is correct, and it splits in two:

- **Limits decide OOM kills.** Keep the memory limit at peak + headroom and never lower it in place below current usage. The kubelet refuses to apply such a change **(lab)**, but a usage spike right after the check is still possible.
- **Requests decide eviction order and how tightly the scheduler packs.** A memory request below real usage frees no RAM. It only lets the scheduler put more pods on the node and makes this pod an early eviction victim. That saving is fake unless usage actually went down.

### 6.4 Idle behaviour is different

- **CPU:** an idle service uses a few millicores. Lowering its request from 500m to 25–50m matches reality, so the saving is real and low-risk.
- **Memory:** an idle service keeps most of its working set (heap, caches, connection pools). Kubernetes cannot make the process give memory back. That has to happen in the runtime, for example:
  - JVM: heap size comes from `-Xmx` or `MaxRAMPercentage` at start-up, and the JVM does not grow its heap after an in-place limit increase. G1 can return unused heap when idle with `-XX:G1PeriodicGCInterval`. ZGC and Shenandoah uncommit idle memory by default. Size the heap to real needs.
  - Go: set `GOMEMLIMIT` close to the target request.
  - Node.js: cap `--max-old-space-size`.
  - .NET: Server GC keeps large heaps. DATAS (on by default since .NET 9) or `GCConserveMemory` shrink them, and Workstation GC is smaller still.
- In-place memory resize is therefore mostly useful for *requests* (scheduling), not for the process's actual footprint.

### 6.5 Scenario comparison (30 services, E5 Flex)

Business hours are Mon–Fri 08:00–20:00 (60 h/week) with 3 replicas × (500m, 1Gi). The rest of the week (108 h) varies:

| Off-hours strategy | USD/month | Saving vs always-on |
|---|---|---|
| A. No change, 3 replicas | 634 | 0% |
| B. 1 replica, full size | 362 | 43% |
| C. 1 replica, CPU request 50m, memory 1Gi | 267 | **58%** |
| D. 1 replica, CPU 500m, memory request 512Mi | 347 | 45% |
| E. 1 replica, CPU 50m + memory 768Mi | 260 | 59% |
| F. 0 replicas (true scale-to-zero) | 226 | 64% |

Halving memory (D) adds 2 points over B. Cutting CPU (C) adds 15. C reaches about 90% of F's saving without any cold start.

### 6.6 Verdict

1. **CPU saves more and is safer to cut.** Shrink idle CPU requests to 25–50m. Keep a CPU limit for JVM services (it fixes the processor count the JVM sees), or set `-XX:ActiveProcessorCount`. For other runtimes the limit is optional.
2. **Memory:** set the request to the measured idle working set + 10–15% and the limit to peak + headroom. Get further reductions from runtime tuning, not from Kubernetes.
3. **After CPU is trimmed, memory dominates the remaining cost.** Pick node shapes with more GB per OCPU (flex shapes allow up to 64 GB/OCPU) so you do not pay for idle CPU on the nodes themselves.

---

## 7. Horizontal layer: never zero, rarely more than needed

[`examples/06-keda-cron-min-one.yaml`](examples/06-keda-cron-min-one.yaml):

```yaml
spec:
  minReplicaCount: 1               # one warm pod, no cold start for the first user
  maxReplicaCount: 10
  triggers:
    - type: cron                   # pre-warm before users arrive
      metadata: { timezone: America/Sao_Paulo, start: "15 7 * * 1-5", end: "0 20 * * 1-5", desiredReplicas: "3" }
    - type: cpu
      metricType: AverageValue     # not Utilization: immune to request changes
      metadata: { value: "400m" }
```

Lab: KEDA created an HPA with the cron external metric and `cpu: AverageValue 400m`, as expected.

Practical points:

- **Pre-warm, then restore.** Run the business-hours restore (5.4) and the cron scale-up 15–30 minutes before traffic arrives, so the morning ramp never waits for a cold start.
- **Request-rate triggers** (Prometheus scaler, or the KEDA HTTP add-on's metrics) follow user load more closely than CPU.
- **Fast scale-out from 1** also needs node capacity. Adding an OKE node takes minutes (OKE images cut provisioning time by more than half compared with platform images). For latency-sensitive services, keep a few low-priority placeholder pods: real pods preempt them instantly, and the autoscaler adds a node for the evicted placeholders in the background.
- **Non-production can go to real zero.** Nobody waits for a cold start at night. Use the Oracle-documented pattern of KEDA cron (+ HTTP add-on for wake-on-request) plus a node pool with min 0 ([Oracle blog](https://blogs.oracle.com/cloud-infrastructure/optimizing-oke-costs-with-keda-and-cluster-autoscaling)), or GoKubeDownscaler.

---

## 8. Node layer: turning smaller requests into a smaller bill

### 8.1 Cluster Autoscaler (OKE add-on)

Configuration: [`examples/09-oke-cluster-autoscaler-addon.json`](examples/09-oke-cluster-autoscaler-addon.json).

```bash
oci ce cluster install-addon --cluster-id <cluster-ocid> --addon-name ClusterAutoscaler \
  --from-json file://examples/09-oke-cluster-autoscaler-addon.json
```

Settings that matter here ([add-on arguments](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/configuration-arguments-cluster-autoscaler.htm)):

| Key | Default | Why it matters |
|---|---|---|
| `scaleDownUtilizationThreshold` | 0.5 | Node "utilization" is the sum of **requests** / capacity. Shrinking requests is what makes nodes removable. 0.6 removes nodes a bit more eagerly |
| `scaleDownUnneededTime` | 10m | How long a node must stay under the threshold |
| `skipNodesWithLocalStorage` | true | Pods with `emptyDir` block scale-down. Set to false if emptyDir content is disposable |
| `nodes` | | `min:max:pool-ocid`. Prod app pools min ≥ 1, non-prod pools min 0 |

OKE best practice: keep one node pool that the autoscaler does not manage for system pods and the autoscaler itself ([best practices](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengbestpractices_topic-Autoscaler-best-practices.htm)). Known issue: when a pool scales up from zero, the autoscaler overestimates the CPU of Arm flex shapes by 2x, which costs one extra scaling cycle ([kubernetes/autoscaler#9337](https://github.com/kubernetes/autoscaler/issues/9337)).

### 8.2 Karpenter Provider for OCI

[`examples/08-karpenter-oci-burstable-and-preemptible.yaml`](examples/08-karpenter-oci-burstable-and-preemptible.yaml) (validated against the KPO v1.4.0 CRDs) defines:

- a **low-cpu** pool on burstable E5/E4 Flex nodes, with consolidation `WhenEmptyOrUnderutilized`;
- a disruption budget that blocks consolidation from 07:00 to 19:00 Mon–Fri (São Paulo time). Karpenter budget schedules have no time zone support, so they are written in UTC;
- a **preemptible** pool (Karpenter `spot`, which KPO maps to OCI preemptible), which requires the `oci.oraclecloud.com/oke-is-preemptible` taint.

Compared with the Cluster Autoscaler, Karpenter can replace a half-empty node with a smaller one and mix shapes in one policy. That matters when off-hours requests shrink unevenly. Do not let both autoscalers manage the same pods ([migration guide](https://blogs.oracle.com/cloud-infrastructure/migrating-to-karpenter-from-cluster-autoscaler)).

### 8.3 Consolidation means cold starts

Removing a node means evicting its pods, and every evicted pod pays a cold start. Mitigations:

- Run 2 replicas with a PodDisruptionBudget (`maxUnavailable: 1`) during business hours. The second replica is cheap after CPU trimming.
- Allow consolidation only in the evening window (Karpenter budgets), right after the shrink, while traffic is low.
- Keep cold starts short with a startup boost (5.3).
- For a single-replica service that must never move, annotate it with `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` or `karpenter.sh/do-not-disrupt: "true"`. That node then stays, so use it sparingly.

### 8.4 Node price levers for the warm pod (50m / 1Gi, 24x7)

| Placement | USD/month |
|---|---|
| E5 Flex, on-demand | 2.12 |
| E5 Flex burstable, 50% baseline | 1.84 |
| E5 Flex burstable, 12.5% baseline | 1.64 |
| A1 Flex (Arm), on-demand | 1.54 |
| Virtual node (Pod.Standard.E4.Flex) | 20.44 + US$0.015/h per virtual node |

- **Burstable nodes** are CPU overcommit priced in by OCI:
  - Kubernetes sees all vCPUs, and you pay for the baseline.
  - If the node's *average* CPU stays below the baseline, every pod gets what it asks for. If it stays above, OCI caps the whole node and every pod slows down.
  - They fit non-prod and services that idle most of the time. Example 08 also shows the safer `kubeReserved` variant, which hides the non-baseline CPU from the scheduler.
  - For a CPU-trimmed pod the gain is small (memory dominates). The gain is large for pools where requests stay high but usage is low.
- **Virtual nodes** do not fit tiny pods. Requests must equal limits, sub-core sizes are not supported, allocation rounds up to whole OCPUs and whole GB plus 0.25 GB overhead, and VPA does not work there ([resource allocation](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengvirtualnodepodresourceallocation.htm), [comparison](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcomparingvirtualwithmanagednodes_topic.htm)). They are useful for stateless burst capacity on top of managed nodes ([Oracle mixed-cluster blog](https://blogs.oracle.com/cloud-infrastructure/mixed-oke-cluster-karpenter-and-virtual-nodes)).
- **Preemptible (−50%)** suits the 2nd to Nth replicas of stateless services, batch and CI. It never suits the only warm replica.
- **Arm (A1/A2)** has the cheapest CPU if your images are multi-arch.

---

## 9. Suggested rollout

| Phase | Actions | Exit criteria |
|---|---|---|
| 0. Measure (1–2 weeks) | Every container has requests. Install Metrics Server (add-on), VPA in `Off` mode ([`02`](examples/02-vpa-recommend-only.yaml)), OpenCost or Goldilocks | Per-service idle and peak CPU/memory known; cost per namespace visible |
| 1. Right-size | Apply VPA recommendations, through GitOps or `InPlaceOrRecreate` + `RequestsOnly` ([`03`](examples/03-vpa-inplace.yaml)). Switch HPAs to `AverageValue` or request rate | Requests within ~20% of p90 usage; no OOM kills or throttling alerts |
| 2. Warm-but-tiny off-hours | KEDA `minReplicaCount: 1` + cron pre-warm ([`06`](examples/06-keda-cron-min-one.yaml)); idle shrinker ([`05`](examples/05-idle-shrinker-cronjob.yaml)) or VPA, not both; startup boost ([`04`](examples/04-vpa-startup-boost.yaml) or [`10`](examples/10-kube-startup-cpu-boost.yaml)). Non-prod to zero | Night-time requests down ≥ 80% for CPU; first-request latency unchanged |
| 3. Capacity | Tune the Cluster Autoscaler add-on ([`09`](examples/09-oke-cluster-autoscaler-addon.json)) or adopt KPO with consolidation windows ([`08`](examples/08-karpenter-oci-burstable-and-preemptible.yaml)); burstable pool for low-CPU services; preemptible for extra replicas; memory-heavier flex ratios | Node count follows requests within ~30 min of the shrink |
| 4. Cold start | Measure start-up time; runtime-level improvements (class-data sharing / AOT cache, native images, lazy init) | If cold start is short enough, revisit true zero for some services |

---

## 10. Risks and caveats

| Risk | Mitigation |
|---|---|
| Memory request below real usage → early eviction under node pressure | Request ≥ idle working set + 10–15% (the shrinker enforces it); PriorityClass for critical services |
| Memory limit lowered below usage → OOM kill | Never lower limits in place; VPA `RequestsOnly` |
| HPA scale-out storm after shrinking requests | `AverageValue` or request-rate metrics only |
| Consolidation evicts the warm pod → cold start | 2 replicas + PDB in the daytime; consolidation windows; startup boost |
| Burstable node above baseline for long → all pods slow | Only low-CPU pools; watch the OCI `CpuUtilization` metric; or use the `kubeReserved` variant |
| Alpha features (VPA `InPlace`, `CPUStartupBoost`) | Test in non-prod; the GA path is `InPlaceOrRecreate` + kube-startup-cpu-boost |
| JVM thread pools sized for a boosted CPU limit | Boost requests only (`RequestsOnly`), modest factors, or `-XX:ActiveProcessorCount` |
| Lab ran containerd, OKE runs CRI-O | Repeat the in-place tests on an OKE dev cluster before production |

---

## 11. Open questions for the team

The answers would change some recommendations:

1. **Runtime and start-up time** (JVM/Spring, .NET, Node, Go?) and how long a cold start takes today. This decides how much the startup boost and runtime tuning help, and whether true zero becomes possible.
2. **Traffic shape:** predictable office hours (schedule-based shrinking is enough) or unpredictable (event-based shrinking needed)?
3. **Environments:** how much of the spend is non-prod? That part can go to real zero today.
4. **Cluster setup:** enhanced or basic clusters, Kubernetes version, and node autoscaler (Cluster Autoscaler or KPO)?
5. **Pricing:** pay-as-you-go or a negotiated rate? Ratios stay the same, absolute savings change.

---

## Appendix A. Files

| Path | Content |
|---|---|
| `examples/01-app-deployment.yaml` | Burstable-QoS workload ready for in-place resize, PDB, opt-in labels |
| `examples/02-vpa-recommend-only.yaml` | VPA in `Off` mode |
| `examples/03-vpa-inplace.yaml` | VPA `InPlaceOrRecreate`, `RequestsOnly`, min/max |
| `examples/04-vpa-startup-boost.yaml` | Same as 03 plus CPU Startup Boost (alpha) |
| `examples/05-idle-shrinker-cronjob.yaml` | RBAC + script + CronJobs for off-hours in-place shrinking |
| `examples/06-keda-cron-min-one.yaml` | KEDA ScaledObject: min 1, cron pre-warm, absolute CPU |
| `examples/07-hpa-absolute-cpu.yaml` | Plain HPA with `AverageValue` |
| `examples/08-karpenter-oci-burstable-and-preemptible.yaml` | KPO OCINodeClass/NodePool: burstable pool with consolidation windows, preemptible pool |
| `examples/09-oke-cluster-autoscaler-addon.json` | OKE Cluster Autoscaler add-on configuration |
| `examples/10-kube-startup-cpu-boost.yaml` | StartupCPUBoost resource |
| `lab/run-lab.sh` | Reproduces every **(lab)** result on kind; `--delete` removes the cluster |
| `lab/cost-model.py` | Generates the cost tables in sections 6 and 8 |

## Appendix B. Sources

- OKE: [supported versions](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengaboutk8sversions.htm), [release notes](https://docs.oracle.com/iaas/releasenotes/services/conteng/), [Kubernetes 1.35 on OKE](https://blogs.oracle.com/cloud-infrastructure/oke-welcomes-kubernetes-1-35), [VPA on OKE](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengusingverticalpodautoscaler.htm), [Cluster Autoscaler](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengusingclusterautoscaler.htm), [CA add-on arguments](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/configuration-arguments-cluster-autoscaler.htm), [autoscaler best practices](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengbestpractices_topic-Autoscaler-best-practices.htm), [KPO](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/conteng-kpo.htm), [KPO GA](https://blogs.oracle.com/cloud-infrastructure/smarter-kubernetes-autoscaling-with-karpenter), [KEDA + CA on OKE](https://blogs.oracle.com/cloud-infrastructure/optimizing-oke-costs-with-keda-and-cluster-autoscaling), [virtual node resources](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengvirtualnodepodresourceallocation.htm), [virtual vs managed nodes](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcomparingvirtualwithmanagednodes_topic.htm), [basic vs enhanced](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcomparingenhancedwithbasicclusters_topic.htm), [preemptible nodes](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengusingpreemptiblecapacity.htm).
- OCI Compute: [burstable instances](https://docs.oracle.com/en-us/iaas/Content/Compute/References/burstable-instances.htm), [burstable billing](https://blogs.oracle.com/cloud-infrastructure/run-your-low-cpu-workloads-more-cost-effectively-with-burstable-vms), [preemptible instances](https://docs.oracle.com/en-us/iaas/Content/Compute/Concepts/preemptible.htm), [Ampere A2 OCPU definition](https://blogs.oracle.com/cloud-infrastructure/introducing-oci-ampere-a2-arm-cloud-compute), [price list API](https://apexapps.oracle.com/pls/apex/cetools/api/v1/products/?currencyCode=USD).
- Kubernetes: [in-place resize](https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/), [1.35 GA blog](https://kubernetes.io/blog/2025/12/19/kubernetes-v1-35-in-place-pod-resize-ga/), [1.36 pod-level resize beta](https://kubernetes.io/blog/2026/04/30/kubernetes-v1-36-inplace-pod-level-resources-beta/), [HPA scale-to-zero beta](https://kubernetes.io/blog/2026/09/02/kubernetes-v1-37-hpa-scale-to-zero-beta/), [node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/).
- VPA: [features](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/features.md), [flags](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/flags.md), [known limitations](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/known-limitations.md), [AEP-7862 CPU startup boost](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler/enhancements/7862-cpu-startup-boost), [VPA 1.8.0 release](https://github.com/kubernetes/autoscaler/releases/tag/vertical-pod-autoscaler-1.8.0).
- Tools: [KEDA](https://keda.sh), [KEDA HTTP add-on](https://github.com/kedacore/http-add-on), [kube-startup-cpu-boost](https://github.com/google/kube-startup-cpu-boost), [Kedify PodResourceProfile](https://docs.kedify.io/how-to/prp-shrink-pod-instead-of-scale-to-zero/), [EPCAS](https://github.com/doordash-oss/elastic-cpu-pod-autoscaler), [OpenCost on OCI](https://www.opencost.io/docs/configuration/oracle), [Karpenter disruption](https://karpenter.sh/docs/concepts/disruption/).
