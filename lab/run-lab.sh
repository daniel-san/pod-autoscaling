#!/usr/bin/env bash
# Reproduces the local validation behind the reports on a kind cluster (Kubernetes 1.36.4,
# the newest GA version on OKE in Oct 2026). Needs: podman or docker, curl, python3.
#
#   ./lab/run-lab.sh            # create cluster (if needed), install add-ons, run checks
#   ./lab/run-lab.sh --delete   # delete the lab cluster
#
# Each step prints what it measured, then one PASS/FAIL line per check, and the run ends
# with a summary. The exit code is 0 only if every check passed. README.md lists the
# expected output.
#
# Differences from OKE: kind uses containerd (OKE uses CRI-O) and has no OCI node
# autoscaling, so only pod-level behaviour is validated here.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
TOOLS=$ROOT/.tools
export PATH=$TOOLS:$PATH
CLUSTER=pod-autoscaling-lab
if command -v podman >/dev/null && ! command -v docker >/dev/null; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
fi

if [[ "${1:-}" == "--delete" ]]; then kind delete cluster --name "$CLUSTER"; exit 0; fi
source lab/lib.sh

pod_of() { kubectl -n demo get pod -l "app=$1" --sort-by=.metadata.creationTimestamp \
             -o jsonpath='{.items[-1:].metadata.name}'; }
show() { kubectl -n demo get pod "$1" -o jsonpath='spec={.spec.containers[0].resources}{"\n"}actual={.status.containerStatuses[0].resources}{"\n"}restarts={.status.containerStatuses[0].restartCount} qos={.status.qosClass}{"\n"}' 2>/dev/null || echo "(pod $1 not found)"; }
res() { kubectl -n demo get pod "$1" -o jsonpath="$2" 2>/dev/null || true; }
req() { res "$1" "{.status.containerStatuses[0].resources.requests.$2}"; }   # applied requests
lim() { res "$1" "{.status.containerStatuses[0].resources.limits.$2}"; }     # applied limits
restarts() { res "$1" '{.status.containerStatuses[0].restartCount}'; }
pod_exists() { kubectl -n demo get pod "$1" >/dev/null 2>&1; }
applied() { [[ "$(req "$1" cpu)" == "$2" && "$(req "$1" memory)" == "$3" ]]; }  # applied <pod> <cpu> <mem>
has_metrics() { kubectl -n demo top pod "$1" --no-headers >/dev/null 2>&1; }

step "Tools"
mkdir -p "$TOOLS"
[[ -x $TOOLS/kind ]]    || curl -sSLo "$TOOLS/kind" https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64
[[ -x $TOOLS/kubectl ]] || curl -sSLo "$TOOLS/kubectl" https://dl.k8s.io/release/v1.36.5/bin/linux/amd64/kubectl
if [[ ! -x $TOOLS/helm ]]; then
  curl -sSL https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz | tar -xz -C /tmp linux-amd64/helm
  mv /tmp/linux-amd64/helm "$TOOLS/helm"
fi
chmod +x "$TOOLS"/*

step "Cluster"
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --config lab/kind-config.yaml
kubectl config use-context "kind-$CLUSTER" >/dev/null

step "Add-ons: metrics-server, VPA 1.8.1 (chart 0.15.0), KEDA 2.21.0"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null 2>&1 || true
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system \
  --set 'args={--kubelet-insecure-tls}' --wait >/dev/null
helm upgrade --install vpa autoscaler/vertical-pod-autoscaler --version 0.15.0 -n kube-system \
  -f lab/vpa-values.yaml --wait >/dev/null
helm upgrade --install keda kedacore/keda --version 2.21.0 -n keda --create-namespace --wait >/dev/null
# Leftovers from an interrupted earlier run would change the results below.
kubectl -n demo delete vpa/my-app vpa/hamster scaledobject/my-app --ignore-not-found >/dev/null 2>&1 || true

step "1. Baseline workload (Burstable QoS, resizePolicy NotRequired)"
kubectl apply -f examples/01-app-deployment.yaml >/dev/null
kubectl -n demo rollout restart deploy/my-app >/dev/null   # start from a fresh pod
kubectl -n demo rollout status deploy/my-app --timeout=180s >/dev/null
P=$(pod_of my-app); show "$P"
expect "QoS class" "$(res "$P" '{.status.qosClass}')" Burstable
expect "requests (CPU/memory)" "$(req "$P" cpu)/$(req "$P" memory)" 500m/256Mi
expect "limits (CPU/memory)" "$(lim "$P" cpu)/$(lim "$P" memory)" 1/512Mi

step "2. Shrink requests in place (limits untouched) -> expect restarts=0"
kubectl -n demo patch pod "$P" --subresource resize \
  -p '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"25m","memory":"64Mi"}}}]}}' >/dev/null
wait_for 30 applied "$P" 25m 64Mi || true
show "$P"
expect "requests applied in place (CPU/memory)" "$(req "$P" cpu)/$(req "$P" memory)" 25m/64Mi
expect "limits unchanged (CPU/memory)" "$(lim "$P" cpu)/$(lim "$P" memory)" 1/512Mi
expect "container restarts" "$(restarts "$P")" 0

step "3. Changing the QoS class in place is rejected"
if out=$(kubectl -n demo patch pod "$P" --subresource resize \
  -p '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"1","memory":"512Mi"}}}]}}' 2>&1); then :; fi
printf '%s\n' "$out" | tail -1
check "resize that would change Burstable to Guaranteed was rejected" grep -q "QOS Class may not change" <<<"$out"
kubectl -n demo patch pod "$P" --subresource resize \
  -p '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"500m","memory":"256Mi"}}}]}}' >/dev/null
wait_for 30 applied "$P" 500m 256Mi || true

step "4. Memory: request below usage is accepted; limit below usage is held back"
kubectl -n demo delete pod memory-hog --ignore-not-found --wait=true >/dev/null
kubectl apply -f lab/memory-hog.yaml >/dev/null
kubectl -n demo wait --for=condition=Ready pod/memory-hog --timeout=120s >/dev/null; sleep 5
kubectl -n demo patch pod memory-hog --subresource resize \
  -p '{"spec":{"containers":[{"name":"hog","resources":{"requests":{"memory":"64Mi"}}}]}}' >/dev/null
kubectl -n demo patch pod memory-hog --subresource resize \
  -p '{"spec":{"containers":[{"name":"hog","resources":{"limits":{"memory":"128Mi"}}}]}}' >/dev/null
sleep 10; show memory-hog
expect "memory request (64Mi, below the ~200Mi in use) applied" "$(req memory-hog memory)" 64Mi
expect "memory limit requested in the spec" "$(res memory-hog '{.spec.containers[0].resources.limits.memory}')" 128Mi
expect "memory limit actually applied (decrease below usage held back)" "$(lim memory-hog memory)" 400Mi
expect "resize condition" "$(res memory-hog '{.status.conditions[?(@.type=="PodResizeInProgress")].type}')" PodResizeInProgress
expect "container restarts" "$(restarts memory-hog)" 0
kubectl -n demo delete pod memory-hog --wait=false >/dev/null

step "5. VPA InPlaceOrRecreate raises an under-requested pod without restart (~1-3 min)"
kubectl -n demo delete -f lab/vpa-hamster.yaml --ignore-not-found --wait=true >/dev/null
kubectl apply -f lab/vpa-hamster.yaml >/dev/null
kubectl -n demo rollout status deploy/hamster --timeout=180s >/dev/null
H=$(pod_of hamster)
raised() { [[ "$(res "$H" '{.spec.containers[0].resources.requests.cpu}')" != 100m ]]; }
wait_for 240 raised || true
if pod_exists "$H"; then
  echo "pod $H (same pod, not recreated):"; show "$H"
  cpu=$(req "$H" cpu)
  check "VPA raised the CPU request in place from 100m (now ${cpu:-nothing})" test "$(cpu_m "${cpu:-0}")" -gt 100
  expect "container restarts" "$(restarts "$H")" 0
else
  fail "VPA recreated pod $H instead of resizing it in place"
fi
kubectl -n demo delete -f lab/vpa-hamster.yaml >/dev/null

step "6. VPA CPU Startup Boost (alpha): boosted at creation, shrunk in place after Ready+30s"
kubectl apply -f examples/04-vpa-startup-boost.yaml >/dev/null; sleep 2
kubectl -n demo rollout restart deploy/my-app >/dev/null
kubectl -n demo rollout status deploy/my-app --timeout=180s >/dev/null
P=$(pod_of my-app); boosted=$(req "$P" cpu)
echo "right after start:"; show "$P"
check "CPU request boosted above the template's 500m while starting (got ${boosted:-nothing})" \
  test "$(cpu_m "${boosted:-0}")" -gt 500
unboosted() { pod_exists "$P" && (( $(cpu_m "$(req "$P" cpu)") < $(cpu_m "${boosted:-0}") )); }
wait_for 90 unboosted || true
echo "after Ready + 30 s:"; show "$P"
check "same pod, not recreated" pod_exists "$P"
check "CPU request lowered in place after start-up (now $(req "$P" cpu))" unboosted
expect "container restarts" "$(restarts "$P")" 0
kubectl -n demo delete -f examples/04-vpa-startup-boost.yaml >/dev/null

step "7. Schedule-based idle shrinker (CronJob), run on demand"
kubectl apply -f examples/01-app-deployment.yaml >/dev/null
kubectl -n demo rollout restart deploy/my-app >/dev/null
kubectl -n demo rollout status deploy/my-app --timeout=180s >/dev/null
P=$(pod_of my-app)
kubectl apply -f examples/05-idle-shrinker-cronjob.yaml >/dev/null
# The shrinker's memory guard needs usage data for the new pod.
wait_for 120 has_metrics "$P" || echo "(no metrics for $P yet: the shrinker will keep its memory request)"
for mode in off-hours business-hours; do
  kubectl -n demo delete job "lab-$mode" --ignore-not-found >/dev/null
  kubectl -n demo create job "lab-$mode" --from="cronjob/idle-shrinker-$mode" >/dev/null
  if kubectl -n demo wait --for=condition=complete "job/lab-$mode" --timeout=180s >/dev/null; then
    kubectl -n demo logs "job/lab-$mode"
    pass "$mode job completed"
  else
    kubectl -n demo logs "job/lab-$mode" || true
    fail "$mode job did not complete within 180 s"
  fi
  if [[ $mode == off-hours ]]; then want=(25m 64Mi); else want=(500m 256Mi); fi
  wait_for 30 applied "$P" "${want[@]}" || true
  show "$P"
  expect "requests after the $mode run (CPU/memory)" "$(req "$P" cpu)/$(req "$P" memory)" "${want[0]}/${want[1]}"
  expect "container restarts" "$(restarts "$P")" 0
done

step "8. KEDA ScaledObject (cron + absolute CPU) creates the expected HPA"
kubectl apply -f examples/06-keda-cron-min-one.yaml >/dev/null
hpa() { kubectl -n demo get hpa keda-hpa-my-app -o jsonpath="$1" 2>/dev/null; }
hpa_exists() { kubectl -n demo get hpa keda-hpa-my-app >/dev/null 2>&1; }
if wait_for 60 hpa_exists; then
  sleep 20   # give the HPA time to read its first metrics; until then TARGETS shows <unknown>
  kubectl -n demo get hpa keda-hpa-my-app
  expect "HPA min/max replicas" "$(hpa '{.spec.minReplicas}/{.spec.maxReplicas}')" 1/10
  expect "CPU target is an absolute amount (AverageValue)" \
    "$(hpa '{.spec.metrics[?(@.type=="Resource")].resource.target.averageValue}')" 400m
  expect "cron trigger present (as an external metric)" "$(hpa '{.spec.metrics[?(@.type=="External")].type}')" External
else
  fail "KEDA did not create the HPA keda-hpa-my-app within 60 s"
fi
kubectl -n demo delete -f examples/06-keda-cron-min-one.yaml >/dev/null
kubectl -n demo scale deploy/my-app --replicas=1 >/dev/null   # the cron trigger may have set 3

step "9. Server-side schema validation of the remaining manifests"
accepted "VPA and HPA examples (02, 03, 07) accepted by the API server" \
  examples/02-vpa-recommend-only.yaml examples/03-vpa-inplace.yaml examples/07-hpa-absolute-cpu.yaml
for f in karpenter.sh_nodepools.yaml karpenter.sh_nodeclaims.yaml oci.oraclecloud.com_ocinodeclasses.yaml; do
  curl -sSL "https://raw.githubusercontent.com/oracle/karpenter-provider-oci/v1.4.0/pkg/apis/crds/$f"
  echo "---"
done | kubectl apply --server-side -f - >/dev/null
accepted "Karpenter Provider for OCI example (08) accepted against the v1.4.0 CRDs" \
  examples/08-karpenter-oci-burstable-and-preemptible.yaml
check "Cluster Autoscaler add-on configuration (09) is valid JSON" \
  python3 -c "import json; json.load(open('examples/09-oke-cluster-autoscaler-addon.json'))"

summary "Next: ./lab/run-runtime-lab.sh, or delete the cluster with ./lab/run-lab.sh --delete"
