#!/usr/bin/env bash
# Reproduces the runtime and scale-to-zero results added in the second revision of the
# reports (Node.js, PHP-FPM, Go, KEDA workers, wake-on-request, namespace downscaler).
# Run ./lab/run-lab.sh first (it creates the kind cluster and the base add-ons).
#
#   ./lab/run-runtime-lab.sh            # all checks (~15 min)
#   ./lab/run-runtime-lab.sh --long     # also the idle-memory probes (~6 min more)
#
# Each step prints what it measured, then one PASS/FAIL/SKIP line per check, and the run
# ends with a summary. The exit code is 0 only if every check passed. README.md lists the
# expected output.
#
# Works with Docker or podman. Docker is used when installed (kind's default); otherwise
# podman. To force one, set KIND_EXPERIMENTAL_PROVIDER=docker|podman before running.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=$PWD/.tools:$PATH
CLUSTER=pod-autoscaling-lab
source lab/lib.sh

detect_engine() {  # sets ENGINE to the container CLI kind uses for its nodes
  if [[ -n "${KIND_EXPERIMENTAL_PROVIDER:-}" ]]; then
    ENGINE=$KIND_EXPERIMENTAL_PROVIDER
  elif command -v docker >/dev/null; then
    ENGINE=docker
  elif command -v podman >/dev/null; then
    ENGINE=podman
    export KIND_EXPERIMENTAL_PROVIDER=podman
  else
    echo "error: neither docker nor podman found" >&2
    return 1
  fi
}
CURRENT_STEP="looking for the lab cluster"
detect_engine
if ! kubectl config use-context "kind-$CLUSTER" >/dev/null 2>&1; then
  echo "error: the lab cluster does not exist. Run ./lab/run-lab.sh first." >&2
  exit 1
fi

cgmem() {  # cgmem <pod> <container> -> memory.current of that container in MiB (number only)
  local cid node
  cid=$(kubectl -n demo get pod "$1" -o jsonpath="{.status.containerStatuses[?(@.name==\"$2\")].containerID}" | sed 's|.*://||')
  node=$(kubectl -n demo get pod "$1" -o jsonpath='{.spec.nodeName}')
  "$ENGINE" exec "$node" sh -c \
    "d=\$(find /sys/fs/cgroup -type d -name '*$cid*' | head -1); echo \$(( \$(cat \$d/memory.current) / 1048576 ))"
}
build_and_load_go_image() {  # builds the tiny Go server used by examples/11c and loads it into kind
  local img=localhost/gohello:lab d tar=/tmp/gohello.tar
  if ! "$ENGINE" image inspect "$img" >/dev/null 2>&1; then
    d=$(mktemp -d)
    printf 'package main\nimport "net/http"\nfunc main(){http.HandleFunc("/",func(w http.ResponseWriter,r *http.Request){w.Write([]byte("ok\\n"))});http.ListenAndServe(":80",nil)}\n' > "$d/main.go"
    printf 'FROM docker.io/library/golang:1.27-alpine AS b\nWORKDIR /s\nCOPY main.go .\nRUN go mod init hello && CGO_ENABLED=0 go build -o /hello .\nFROM scratch\nCOPY --from=b /hello /hello\nENTRYPOINT ["/hello"]\n' > "$d/Containerfile"
    # -f is needed for Docker, which only looks for a file named Dockerfile by default.
    "$ENGINE" build -q -f "$d/Containerfile" -t "$img" "$d" >/dev/null
    rm -rf "$d"
  fi
  rm -f "$tar"   # podman refuses to overwrite an existing archive
  "$ENGINE" save -o "$tar" "$img" >/dev/null
  kind load image-archive "$tar" --name "$CLUSTER" >/dev/null 2>&1
  rm -f "$tar"
}
waitzero() {  # waitzero <ns> <deploy>: wait up to 5 min for 0 replicas and no pods
  for _ in $(seq 1 60); do
    [[ "$(kubectl -n "$1" get deploy "$2" -o jsonpath='{.spec.replicas}')" == "0" ]] &&
      [[ -z "$(kubectl -n "$1" get pods -l "app=$2" --no-headers 2>/dev/null)" ]] && return 0
    sleep 5
  done
  return 1
}
waitreplicas() {  # waitreplicas <ns> <deploy> <count>: wait up to 150 s for that replica count
  for _ in $(seq 1 30); do
    [[ "$(kubectl -n "$1" get deploy "$2" -o jsonpath='{.spec.replicas}')" == "$3" ]] && return 0
    sleep 5
  done
  return 1
}
lastlog() { kubectl -n demo logs "$1" --tail=1 2>/dev/null || true; }
field() { sed -n "s/.*$1=\([0-9]*\).*/\1/p" <<<"$2"; }     # field NAME "<log line>" -> number
podres() { kubectl -n demo get pod "$1" -o jsonpath="$2" 2>/dev/null || true; }
NODE_CPUS=$(kubectl get node pod-autoscaling-lab-worker -o jsonpath='{.status.capacity.cpu}')
min() { echo $(( $1 < $2 ? $1 : $2 )); }

step "Add-ons: KEDA HTTP add-on 0.16.0, GoKubeDownscaler 1.4.2"
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo add caas-team https://caas-team.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install keda kedacore/keda --version 2.21.0 -n keda --create-namespace --wait >/dev/null
helm upgrade --install http-add-on kedacore/keda-add-ons-http --version 0.16.0 -n keda --wait >/dev/null
helm upgrade --install go-kube-downscaler caas-team/go-kube-downscaler --version 1.4.2 \
  -n kube-downscaler --create-namespace --wait >/dev/null
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "1. Go: GOMAXPROCS follows an in-place CPU limit change (floor of 2)"
kubectl -n demo delete -f lab/runtime-go.yaml --ignore-not-found --wait=true >/dev/null
kubectl apply -f lab/runtime-go.yaml >/dev/null
kubectl -n demo wait --for=condition=Ready pod/go-probe --timeout=300s >/dev/null
go_started() { lastlog go-probe | grep -q GOMAXPROCS; }
limit_cpu_is() { [[ "$(podres go-probe '{.status.containerStatuses[0].resources.limits.cpu}')" == "$1" ]]; }
gomax_is() { [[ "$(field GOMAXPROCS "$(lastlog go-probe)")" == "$1" ]]; }
if wait_for 300 go_started; then
  line=$(lastlog go-probe); echo "$line"
  floor=$(min 2 "$(field NumCPU "$line")")   # 2, or fewer on a machine with fewer CPUs
  expect "GOMAXPROCS with a CPU limit of 2" "$(field GOMAXPROCS "$line")" "$floor"
  for cpu in 1 3; do
    kubectl -n demo patch pod go-probe --subresource resize \
      -p "{\"spec\":{\"containers\":[{\"name\":\"app\",\"resources\":{\"limits\":{\"cpu\":\"$cpu\",\"memory\":\"1Gi\"}}}]}}" >/dev/null
    wait_for 20 limit_cpu_is "$cpu" || true
    if [[ $cpu == 1 ]]; then
      sleep 5   # the runtime re-reads the limit at most once per second
      line=$(lastlog go-probe); echo "after limit cpu=1: $line"
      expect "GOMAXPROCS with a CPU limit of 1 (the runtime never goes below 2)" "$(field GOMAXPROCS "$line")" "$floor"
    else
      want=$(min 3 "$(field NumCPU "$line")")
      wait_for 20 gomax_is "$want" || true
      line=$(lastlog go-probe); echo "after limit cpu=3: $line"
      expect "GOMAXPROCS follows the new CPU limit of 3" "$(field GOMAXPROCS "$line")" "$want"
      expect "GOMEMLIMIT (MiB) stays at its start-up value after the memory resize" "$(field GOMEMLIMIT "$line")" 768
    fi
  done
  expect "container restarts" "$(podres go-probe '{.status.containerStatuses[0].restartCount}')" 0
else
  fail "Go probe did not start within 300 s"
fi
kubectl -n demo delete -f lab/runtime-go.yaml --wait=false >/dev/null

step "2. Node.js: heap limit from the memory limit at start-up; not updated by resize"
kubectl -n demo delete -f lab/runtime-node.yaml --ignore-not-found --wait=true >/dev/null
kubectl apply -f lab/runtime-node.yaml >/dev/null
kubectl -n demo wait --for=condition=Ready pod/node-default pod/node-percentage --timeout=180s >/dev/null
node_started() { lastlog node-default | grep -q heap_limit && lastlog node-percentage | grep -q heap_limit; }
wait_for 60 node_started || true
declare -A heap_before
for p in node-default node-percentage; do
  line=$(lastlog "$p"); echo "$p:"; echo "$line"; heap_before[$p]=$(field heap_limit "$line")
done
d=${heap_before[node-default]:-0} pc=${heap_before[node-percentage]:-0}
check "default heap limit is about 50% of the 512Mi memory limit (${d} MiB)" test "$d" -ge 205 -a "$d" -le 310
check "with --max-old-space-size-percentage=75 it is about 75% (${pc} MiB)" test "$pc" -ge 355 -a "$pc" -le 410
for p in node-default node-percentage; do
  kubectl -n demo patch pod "$p" --subresource resize \
    -p '{"spec":{"containers":[{"name":"app","resources":{"limits":{"cpu":"2","memory":"1Gi"}}}]}}' >/dev/null
done
sees_1gi() { [[ "$(field constrainedMemory "$(lastlog "$1")")" == 1024 ]]; }
for p in node-default node-percentage; do
  wait_for 30 sees_1gi "$p" || true
  line=$(lastlog "$p"); echo "$p after resize to 2 CPU / 1Gi:"; echo "$line"
  expect "$p sees the new memory limit (constrainedMemory, MiB)" "$(field constrainedMemory "$line")" 1024
  expect "$p availableParallelism follows the new CPU limit" "$(field availableParallelism "$line")" "$(min 2 "$NODE_CPUS")"
  expect "$p heap limit (MiB) not recalculated after the resize" "$(field heap_limit "$line")" "${heap_before[$p]}"
done
kubectl -n demo delete -f lab/runtime-node.yaml --wait=false >/dev/null

step "3. PHP-FPM: pm=ondemand returns worker memory when idle, pm=static keeps it"
kubectl -n demo delete -f lab/runtime-php.yaml --ignore-not-found --wait=true >/dev/null
kubectl apply -f lab/runtime-php.yaml >/dev/null
kubectl -n demo wait --for=condition=Ready pod/php-ondemand pod/php-static --timeout=180s >/dev/null
IP1=$(kubectl -n demo get pod php-ondemand -o jsonpath='{.status.podIP}')
IP2=$(kubectl -n demo get pod php-static -o jsonpath='{.status.podIP}')
echo "before: ondemand=$(cgmem php-ondemand php)MiB static=$(cgmem php-static php)MiB"
kubectl -n demo delete pod loadgen --ignore-not-found >/dev/null
kubectl -n demo run loadgen --image=busybox:1.37 --restart=Never -- sh -c \
  "for ip in $IP1 $IP2; do for c in 1 2 3 4 5 6 7 8; do (e=\$((\$(date +%s)+20)); while [ \$(date +%s) -lt \$e ]; do wget -q -O- http://\$ip:8080/ >/dev/null; done) & done; done; wait" >/dev/null
kubectl -n demo wait --for=jsonpath='{.status.phase}'=Succeeded pod/loadgen --timeout=120s >/dev/null
od=$(cgmem php-ondemand php); st=$(cgmem php-static php)
echo "right after load: ondemand=${od}MiB static=${st}MiB"
check "both pools grew under load (ondemand ${od} MiB, static ${st} MiB)" test "$od" -ge 100 -a "$st" -ge 100
T0=$SECONDS
ondemand_idle() { (( $(cgmem php-ondemand php) < 25 )); }   # ~10 MiB once all workers exit
wait_for 60 ondemand_idle || true
od=$(cgmem php-ondemand php); st=$(cgmem php-static php)
echo "$((SECONDS - T0)) s idle: ondemand=${od}MiB static=${st}MiB"
check "pm=ondemand returned its worker memory when idle (${od} MiB)" test "$od" -lt 25
check "pm=static kept its worker memory (${st} MiB)" test "$st" -ge 100
kubectl -n demo delete -f lab/runtime-php.yaml --wait=false >/dev/null
kubectl -n demo delete pod loadgen --wait=false >/dev/null

step "4. A pod with a shrunk CPU request still bursts to its limit"
kubectl -n demo delete pod burst --ignore-not-found >/dev/null
kubectl -n demo run burst --image=busybox:1.37 --restart=Never --overrides='{"spec":{"containers":[{"name":"burst","image":"busybox:1.37","command":["sh","-c","while true; do :; done"],"resources":{"requests":{"cpu":"500m","memory":"16Mi"},"limits":{"cpu":"1","memory":"32Mi"}}}]}}' >/dev/null
kubectl -n demo wait --for=condition=Ready pod/burst --timeout=60s >/dev/null
kubectl -n demo patch pod burst --subresource resize -p '{"spec":{"containers":[{"name":"burst","resources":{"requests":{"cpu":"25m"}}}]}}' >/dev/null
burst_req() { podres burst '{.status.containerStatuses[0].resources.requests.cpu}'; }
burst_shrunk() { [[ "$(burst_req)" == 25m ]]; }
wait_for 30 burst_shrunk || true
expect "CPU request shrunk in place" "$(burst_req)" 25m
sleep 45   # let metrics-server collect usage from after the resize
top_cpu() { kubectl top pod -n demo burst --no-headers 2>/dev/null | awk '{print $2}'; }
have_top() { [[ -n "$(top_cpu)" ]]; }
wait_for 90 have_top || true
kubectl top pod -n demo burst || true
used=$(top_cpu)
check "uses far more CPU than its 25m request when the node has spare CPU (${used:-no data}; limit 1000m)" \
  test "$(cpu_m "${used:-0}")" -ge 500
kubectl -n demo delete pod burst --wait=false >/dev/null

step "5. Runtime examples + off-hours shrinker (multi-container PHP pod included)"
build_and_load_go_image
kubectl apply -f examples/11a-runtime-nodejs.yaml -f examples/11b-runtime-php-fpm.yaml -f examples/11c-runtime-go.yaml >/dev/null
for d in node-api php-api go-api; do kubectl -n demo rollout status "deploy/$d" --timeout=180s >/dev/null; done
kubectl apply -f examples/05-idle-shrinker-cronjob.yaml >/dev/null
runtime_metrics() { (( $(kubectl -n demo top pod -l 'app in (node-api,php-api,go-api)' --no-headers 2>/dev/null | wc -l) >= 3 )); }
wait_for 120 runtime_metrics || echo "(no metrics yet: the shrinker will keep memory requests unchanged)"
for mode in off-hours business-hours; do
  kubectl -n demo delete job "rt-$mode" --ignore-not-found >/dev/null
  kubectl -n demo create job "rt-$mode" --from="cronjob/idle-shrinker-$mode" >/dev/null
  echo "-- $mode"
  if kubectl -n demo wait --for=condition=complete "job/rt-$mode" --timeout=180s >/dev/null; then
    kubectl -n demo logs "job/rt-$mode" | grep -E '^(idle|active)' || true
    pass "$mode job completed"
  else
    kubectl -n demo logs "job/rt-$mode" || true
    fail "$mode job did not complete within 180 s"
  fi
  [[ $mode == off-hours ]] && check_mode=idle || check_mode=active
  for _ in $(seq 1 10); do   # the kubelet applies the patches within a few seconds
    # The Deployments carry the app label only on their pods, so fetch them by name.
    verdicts=$({ kubectl -n demo get deploy node-api php-api go-api -o json
                 kubectl -n demo get pod -l 'app in (node-api,php-api,go-api)' -o json; } \
               | python3 lab/shrink_check.py "$check_mode") ||
      verdicts="bad lab/shrink_check.py could not read the pods (error above)"
    grep -q '^bad' <<<"$verdicts" || break
    sleep 3
  done
  while read -r verdict text; do
    if [[ $verdict == ok ]]; then pass "$text"; else fail "$text"; fi
  done <<<"$verdicts"
done

step "6. Queue worker scales 0 -> N -> 0 with KEDA (redis list)"
kubectl apply -f lab/redis.yaml >/dev/null; kubectl -n demo rollout status deploy/redis --timeout=120s >/dev/null
kubectl apply -f examples/14-keda-queue-worker-zero.yaml >/dev/null; sleep 15
R=$(kubectl -n demo get pod -l app=redis -o name)
worker_replicas() { local r; r=$(kubectl -n demo get deploy jobs-worker -o jsonpath="{.$1}" 2>/dev/null || true); echo "${r:-0}"; }
worker_ready() { (( $(worker_replicas status.readyReplicas) >= 1 )); }
queue_len() { kubectl -n demo exec "$R" -- redis-cli LLEN jobs; }
if waitzero demo jobs-worker; then
  pass "worker at 0 replicas while the queue is empty"
  T0=$SECONDS
  kubectl -n demo exec "$R" -- sh -c 'for i in $(seq 1 100); do redis-cli LPUSH jobs j$i >/dev/null; done'
  if wait_for 120 worker_ready; then
    pass "first worker Ready $((SECONDS - T0)) s after 100 jobs were queued"
    maxr=0 drained=''
    for _ in $(seq 1 90); do
      r=$(worker_replicas spec.replicas); if (( r > maxr )); then maxr=$r; fi
      if [[ "$(queue_len)" == 0 ]]; then drained=1; break; fi
      sleep 2
    done
    check "scaled out to more than 1 worker for the backlog (max ${maxr})" test "$maxr" -ge 2
    if [[ -n $drained ]]; then
      pass "queue drained $((SECONDS - T0)) s after the jobs were queued"
      T1=$SECONDS
      if waitzero demo jobs-worker; then
        pass "back to 0 replicas $((SECONDS - T1)) s after the queue drained"
      else
        fail "worker did not scale back to 0 within 5 min of the queue draining"
      fi
    else
      fail "queue not drained within 180 s ($(queue_len) jobs left)"
    fi
  else
    fail "no worker became Ready within 120 s of the first job"
  fi
else
  fail "worker did not stay at 0 replicas with an empty queue"
fi

step "7. Wake-on-request from zero through the KEDA HTTP interceptor"
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n dev delete deploy web --ignore-not-found --wait=true >/dev/null
# Lab only: drop the office-hours cron trigger, so the test can reach zero at any time of
# day, and shorten the cooldown. The example file itself is not changed.
awk '/^    - type: cron/{skip=1; next} /^    - type: external-push/{skip=0} !skip' \
    examples/12-nonprod-wake-on-request.yaml \
  | sed 's/cooldownPeriod: 600 /cooldownPeriod: 30  /' | kubectl apply -f - >/dev/null
kubectl -n dev delete pod client --ignore-not-found >/dev/null
kubectl -n dev run client --image=busybox:1.37 --restart=Never -- sleep 3600 >/dev/null
kubectl -n dev wait --for=condition=Ready pod/client --timeout=60s >/dev/null
for run in 1 2 3; do
  if ! waitzero dev web; then fail "web did not scale to 0 replicas before cold request $run"; continue; fi
  if out=$(kubectl -n dev exec client -- sh -c 'time wget -q -O /dev/null --header "Host: web.dev.example.com" http://keda-add-ons-http-interceptor-proxy.keda:8080/' 2>&1); then
    t=$(awk '/real/ { t = $2 " " $3; sub(/^0m /, "", t); print t }' <<<"$out")
    pass "cold request $run (app at 0 replicas) answered in ${t:-?}"
  else
    printf '%s\n' "$out"; fail "cold request $run (app at 0 replicas) failed"
  fi
done
echo "(the example's office-hours cron trigger was left out for this test)"

step "8. Whole namespace to zero outside office hours (GoKubeDownscaler)"
kubectl apply -f examples/13-nonprod-namespace-downscaler.yaml >/dev/null
kubectl -n staging create deployment api --image=nginx:1.29-alpine --replicas=3 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl annotate ns staging downscaler/grace-period=0s --overwrite >/dev/null   # lab only (default 15 min)
# Inside the uptime window the downscaler correctly keeps everything up, so force
# downtime for the test. 10# makes bash read "0904" as decimal, not octal.
now=$((10#$(TZ=America/Sao_Paulo date +%H%M)))
if (( $(TZ=America/Sao_Paulo date +%u) <= 5 && now >= 730 && now < 2000 )); then
  echo "inside the uptime window now: forcing downtime for the test"
  kubectl annotate ns staging downscaler/force-downtime=true --overwrite >/dev/null
fi
if waitreplicas staging api 0; then pass "staging/api scaled to 0 replicas outside the uptime window"
else fail "staging/api did not scale to 0 within 150 s"; fi
kubectl -n staging get deploy
expect "excluded workload kept running (always-on-tool replicas)" \
  "$(kubectl -n staging get deploy always-on-tool -o jsonpath='{.spec.replicas}')" 1
kubectl annotate ns staging downscaler/force-downtime- downscaler/force-uptime=true --overwrite >/dev/null
if waitreplicas staging api 3; then pass "staging/api restored to 3 replicas when uptime began"
else fail "staging/api was not restored to 3 replicas within 150 s"; fi
kubectl annotate ns staging downscaler/force-uptime- >/dev/null

step "9. Placeholder pods give spikes instant room"
W=pod-autoscaling-lab-worker
ALLOC=$(kubectl get node "$W" -o jsonpath='{.status.allocatable.cpu}')
REQ=$(kubectl describe node "$W" | awk '/Allocated resources/{f=1} f && /^ +cpu/{print $2; exit}')
FREE=$(( $(cpu_m "$ALLOC") - $(cpu_m "$REQ") ))
if (( FREE < 2500 )); then
  skip "needs 2.5 CPUs not yet requested on node $W; it has ${FREE}m free (needs a machine with more CPU cores)"
else
  PH=$((FREE - 500))
  sed -e "s/requests: { cpu: \"1\", memory: 1Gi }    # = one full-size replica/requests: { cpu: \"${PH}m\", memory: 1Gi }/" \
      -e "s/limits: { cpu: \"1\", memory: 1Gi }/limits: { cpu: \"${PH}m\", memory: 1Gi }/" \
      examples/15-capacity-placeholder.yaml | kubectl apply -f - >/dev/null
  kubectl -n demo rollout status deploy/capacity-placeholder --timeout=60s >/dev/null
  echo "placeholder holds ${PH}m CPU; only 500m left free on the node"
  kubectl -n demo delete pod real-pod --ignore-not-found --wait=true >/dev/null
  T0=$SECONDS
  kubectl -n demo run real-pod --image=nginx:1.29-alpine --restart=Never --overrides='{"spec":{"containers":[{"name":"real-pod","image":"nginx:1.29-alpine","resources":{"requests":{"cpu":"2","memory":"64Mi"}}}]}}' >/dev/null
  if kubectl -n demo wait --for=condition=Ready pod/real-pod --timeout=60s >/dev/null; then
    took=$((SECONDS - T0))
    check "2-CPU pod Ready within 10 s by taking the placeholder's room (${took} s)" test "$took" -le 10
  else
    fail "2-CPU pod not Ready within 60 s"
  fi
  placeholder_pending() { [[ "$(kubectl -n demo get pods -l app=capacity-placeholder -o jsonpath='{.items[*].status.phase}')" == Pending ]]; }
  wait_for 20 placeholder_pending || true
  expect "placeholder evicted and waiting for room (on OKE the autoscaler adds a node)" \
    "$(kubectl -n demo get pods -l app=capacity-placeholder -o jsonpath='{.items[*].status.phase}')" Pending
  kubectl -n demo delete pod real-pod --wait=false >/dev/null
fi
sed -n '/^---/,$p' examples/15-capacity-placeholder.yaml | kubectl delete -f - --wait=false >/dev/null 2>&1 || true
kubectl delete priorityclass capacity-placeholder --ignore-not-found >/dev/null

step "10. Server-side validation of the new manifests"
accepted "examples 11a to 15 accepted by the API server" \
  examples/11a-runtime-nodejs.yaml examples/11b-runtime-php-fpm.yaml examples/11c-runtime-go.yaml \
  examples/12-nonprod-wake-on-request.yaml examples/13-nonprod-namespace-downscaler.yaml \
  examples/14-keda-queue-worker-zero.yaml examples/15-capacity-placeholder.yaml

if [[ "${1:-}" == "--long" ]]; then
  step "11. Idle memory after a burst (Node.js and Go), about 6 minutes"
  kubectl -n demo delete -f lab/runtime-idle.yaml --ignore-not-found --wait=true >/dev/null
  kubectl apply -f lab/runtime-idle.yaml >/dev/null
  kubectl -n demo wait --for=condition=Ready pod/idle-node pod/idle-go --timeout=300s >/dev/null
  # The Go runtime returns memory about 4.5 min after the burst; wait until 5.5 min.
  idle_done() { local t; t=$(sed -n 's/.* t=\([0-9]*\)s.*/\1/p' <<<"$(lastlog idle-go)"); (( ${t:-0} >= 330 )); }
  wait_for 600 idle_done || true
  for p in idle-node idle-go; do
    echo "-- $p"; kubectl -n demo logs "$p" | awk '{print $2, $3}' | uniq -f1
    first=$(kubectl -n demo logs "$p" | sed -n '1s/.* rss=\([0-9]*\)MiB.*/\1/p')
    last=$(field rss "$(lastlog "$p")")
    check "$p returned its burst memory to the OS (${first:-?} -> ${last:-?} MiB)" \
      test "${last:-999999}" -le "$(( ${first:-0} / 2 ))"
  done
  kubectl -n demo delete -f lab/runtime-idle.yaml --wait=false >/dev/null
fi

summary "The cluster is still running; delete it with ./lab/run-lab.sh --delete"
