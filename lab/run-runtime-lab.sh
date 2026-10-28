#!/usr/bin/env bash
# Reproduces the runtime and scale-to-zero results added in the second revision of the
# reports (Node.js, PHP-FPM, Go, KEDA workers, wake-on-request, namespace downscaler).
# Run ./lab/run-lab.sh first (it creates the kind cluster and the base add-ons).
#
#   ./lab/run-runtime-lab.sh            # all checks (~15 min)
#   ./lab/run-runtime-lab.sh --long     # also the 6-minute idle-memory probes
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=$PWD/.tools:$PATH
CLUSTER=pod-autoscaling-lab
if command -v podman >/dev/null && ! command -v docker >/dev/null; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
cgmem() {  # cgmem <pod> <container> -> memory.current of that container in MiB
  local cid node
  cid=$(kubectl -n demo get pod "$1" -o jsonpath="{.status.containerStatuses[?(@.name==\"$2\")].containerID}" | sed 's|.*://||')
  node=$(kubectl -n demo get pod "$1" -o jsonpath='{.spec.nodeName}')
  ${KIND_EXPERIMENTAL_PROVIDER:-docker} exec "$node" sh -c \
    "d=\$(find /sys/fs/cgroup -type d -name '*$cid*' | head -1); echo \$(( \$(cat \$d/memory.current) / 1048576 ))MiB"
}
waitzero() {  # waitzero <ns> <deploy>
  for _ in $(seq 1 60); do
    [[ "$(kubectl -n "$1" get deploy "$2" -o jsonpath='{.spec.replicas}')" == "0" ]] &&
      [[ -z "$(kubectl -n "$1" get pods -l "app=$2" --no-headers 2>/dev/null)" ]] && return 0
    sleep 5
  done
  return 1
}

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
until kubectl -n demo logs go-probe 2>/dev/null | grep -q GOMAXPROCS; do sleep 3; done
kubectl -n demo logs go-probe --tail=1
for cpu in 1 3; do
  kubectl -n demo patch pod go-probe --subresource resize \
    -p "{\"spec\":{\"containers\":[{\"name\":\"app\",\"resources\":{\"limits\":{\"cpu\":\"$cpu\",\"memory\":\"1Gi\"}}}]}}" >/dev/null
  sleep 5; echo "after limit cpu=$cpu:"; kubectl -n demo logs go-probe --tail=1
done
kubectl -n demo delete -f lab/runtime-go.yaml --wait=false >/dev/null

step "2. Node.js: heap limit from the memory limit at start-up; not updated by resize"
kubectl -n demo delete -f lab/runtime-node.yaml --ignore-not-found --wait=true >/dev/null
kubectl apply -f lab/runtime-node.yaml >/dev/null
kubectl -n demo wait --for=condition=Ready pod/node-default pod/node-percentage --timeout=180s >/dev/null; sleep 4
for p in node-default node-percentage; do echo "$p:"; kubectl -n demo logs "$p" --tail=1; done
for p in node-default node-percentage; do
  kubectl -n demo patch pod "$p" --subresource resize \
    -p '{"spec":{"containers":[{"name":"app","resources":{"limits":{"cpu":"2","memory":"1Gi"}}}]}}' >/dev/null
done
sleep 6; for p in node-default node-percentage; do echo "$p after resize to 2 CPU / 1Gi:"; kubectl -n demo logs "$p" --tail=1; done
kubectl -n demo delete -f lab/runtime-node.yaml --wait=false >/dev/null

step "3. PHP-FPM: pm=ondemand returns worker memory when idle, pm=static keeps it"
kubectl -n demo delete -f lab/runtime-php.yaml --ignore-not-found --wait=true >/dev/null
kubectl apply -f lab/runtime-php.yaml >/dev/null
kubectl -n demo wait --for=condition=Ready pod/php-ondemand pod/php-static --timeout=180s >/dev/null
IP1=$(kubectl -n demo get pod php-ondemand -o jsonpath='{.status.podIP}')
IP2=$(kubectl -n demo get pod php-static -o jsonpath='{.status.podIP}')
echo "before: ondemand=$(cgmem php-ondemand php) static=$(cgmem php-static php)"
kubectl -n demo delete pod loadgen --ignore-not-found >/dev/null
kubectl -n demo run loadgen --image=busybox:1.37 --restart=Never -- sh -c \
  "for ip in $IP1 $IP2; do for c in 1 2 3 4 5 6 7 8; do (e=\$((\$(date +%s)+20)); while [ \$(date +%s) -lt \$e ]; do wget -q -O- http://\$ip:8080/ >/dev/null; done) & done; done; wait" >/dev/null
kubectl -n demo wait --for=jsonpath='{.status.phase}'=Succeeded pod/loadgen --timeout=120s >/dev/null
echo "right after load: ondemand=$(cgmem php-ondemand php) static=$(cgmem php-static php)"
sleep 25
echo "25 s idle: ondemand=$(cgmem php-ondemand php) static=$(cgmem php-static php)"
kubectl -n demo delete -f lab/runtime-php.yaml --wait=false >/dev/null
kubectl -n demo delete pod loadgen --wait=false >/dev/null

step "4. A pod with a shrunk CPU request still bursts to its limit"
kubectl -n demo delete pod burst --ignore-not-found >/dev/null
kubectl -n demo run burst --image=busybox:1.37 --restart=Never --overrides='{"spec":{"containers":[{"name":"burst","image":"busybox:1.37","command":["sh","-c","while true; do :; done"],"resources":{"requests":{"cpu":"500m","memory":"16Mi"},"limits":{"cpu":"1","memory":"32Mi"}}}]}}' >/dev/null
kubectl -n demo wait --for=condition=Ready pod/burst --timeout=60s >/dev/null
kubectl -n demo patch pod burst --subresource resize -p '{"spec":{"containers":[{"name":"burst","resources":{"requests":{"cpu":"25m"}}}]}}' >/dev/null
sleep 75; kubectl top pod -n demo burst
kubectl -n demo delete pod burst --wait=false >/dev/null

step "5. Runtime examples + off-hours shrinker (multi-container PHP pod included)"
podman image exists localhost/gohello:lab 2>/dev/null || {
  d=$(mktemp -d)
  printf 'package main\nimport "net/http"\nfunc main(){http.HandleFunc("/",func(w http.ResponseWriter,r *http.Request){w.Write([]byte("ok\\n"))});http.ListenAndServe(":80",nil)}\n' > "$d/main.go"
  printf 'FROM docker.io/library/golang:1.27-alpine AS b\nWORKDIR /s\nCOPY main.go .\nRUN go mod init hello && CGO_ENABLED=0 go build -o /hello .\nFROM scratch\nCOPY --from=b /hello /hello\nENTRYPOINT ["/hello"]\n' > "$d/Containerfile"
  podman build -q -t localhost/gohello:lab "$d" >/dev/null
}
rm -f /tmp/gohello.tar
podman save -o /tmp/gohello.tar localhost/gohello:lab >/dev/null
kind load image-archive /tmp/gohello.tar --name "$CLUSTER" >/dev/null 2>&1
kubectl apply -f examples/11a-runtime-nodejs.yaml -f examples/11b-runtime-php-fpm.yaml -f examples/11c-runtime-go.yaml >/dev/null
for d in node-api php-api go-api; do kubectl -n demo rollout status "deploy/$d" --timeout=180s >/dev/null; done
kubectl apply -f examples/05-idle-shrinker-cronjob.yaml >/dev/null
sleep 60   # let metrics-server report usage for the memory guard
for mode in off-hours business-hours; do
  kubectl -n demo delete job "rt-$mode" --ignore-not-found >/dev/null
  kubectl -n demo create job "rt-$mode" --from="cronjob/idle-shrinker-$mode" >/dev/null
  kubectl -n demo wait --for=condition=complete "job/rt-$mode" --timeout=180s >/dev/null
  echo "-- $mode"; kubectl -n demo logs "job/rt-$mode" | grep -E '^(idle|active)'
done
kubectl -n demo get pods -l 'app in (node-api,php-api,go-api)' \
  -o jsonpath='{range .items[*]}{.metadata.name}{range .status.containerStatuses[*]} [{.name} restarts={.restartCount}]{end}{"\n"}{end}'

step "6. Queue worker scales 0 -> N -> 0 with KEDA (redis list)"
kubectl apply -f lab/redis.yaml >/dev/null; kubectl -n demo rollout status deploy/redis --timeout=120s >/dev/null
kubectl apply -f examples/14-keda-queue-worker-zero.yaml >/dev/null; sleep 15
R=$(kubectl -n demo get pod -l app=redis -o name)
T0=$(date +%s)
kubectl -n demo exec "$R" -- sh -c 'for i in $(seq 1 100); do redis-cli LPUSH jobs j$i >/dev/null; done'
until [[ "$(kubectl -n demo get deploy jobs-worker -o jsonpath='{.status.readyReplicas}')" -ge 1 ]] 2>/dev/null; do sleep 1; done
echo "first worker Ready $(( $(date +%s) - T0 )) s after the first job"
until [[ "$(kubectl -n demo exec "$R" -- redis-cli LLEN jobs)" == "0" ]]; do sleep 2; done
T1=$(date +%s); waitzero demo jobs-worker && echo "back to 0 replicas $(( $(date +%s) - T1 )) s after the queue drained"

step "7. Wake-on-request from zero through the KEDA HTTP interceptor"
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n dev delete deploy web --ignore-not-found --wait=true >/dev/null
sed 's/cooldownPeriod: 600 /cooldownPeriod: 30  /' examples/12-nonprod-wake-on-request.yaml | kubectl apply -f - >/dev/null
kubectl -n dev delete pod client --ignore-not-found >/dev/null
kubectl -n dev run client --image=busybox:1.37 --restart=Never -- sleep 3600 >/dev/null
kubectl -n dev wait --for=condition=Ready pod/client --timeout=60s >/dev/null
for run in 1 2 3; do
  waitzero dev web
  kubectl -n dev exec client -- sh -c 'time wget -q -O /dev/null --header "Host: web.dev.example.com" http://keda-add-ons-http-interceptor-proxy.keda:8080/' 2>&1 \
    | awk -v r="$run" '/real/ {print "cold request " r ": " $2 " " $3}'
done
echo "(outside 07:30-20:00 America/Sao_Paulo the cron trigger is inactive, so the app sits at 0)"

step "8. Whole namespace to zero outside office hours (GoKubeDownscaler)"
kubectl apply -f examples/13-nonprod-namespace-downscaler.yaml >/dev/null
kubectl -n staging create deployment api --image=nginx:1.29-alpine --replicas=3 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl annotate ns staging downscaler/grace-period=0s --overwrite >/dev/null   # lab only (default 15 min)
if [[ "$(TZ=America/Sao_Paulo date +%u)" -le 5 && "$(TZ=America/Sao_Paulo date +%H%M)" -ge 0730 && "$(TZ=America/Sao_Paulo date +%H%M)" -lt 2000 ]]; then
  echo "inside the uptime window now: forcing downtime for the test"
  kubectl annotate ns staging downscaler/force-downtime=true --overwrite >/dev/null
fi
for _ in $(seq 1 30); do [[ "$(kubectl -n staging get deploy api -o jsonpath='{.spec.replicas}')" == "0" ]] && break; sleep 5; done
kubectl -n staging get deploy
kubectl annotate ns staging downscaler/force-downtime- downscaler/force-uptime=true --overwrite >/dev/null
for _ in $(seq 1 30); do [[ "$(kubectl -n staging get deploy api -o jsonpath='{.spec.replicas}')" == "3" ]] && break; sleep 5; done
echo "after force-uptime:"; kubectl -n staging get deploy api
kubectl annotate ns staging downscaler/force-uptime- >/dev/null

step "9. Placeholder pods give spikes instant room"
W=pod-autoscaling-lab-worker
ALLOC=$(kubectl get node "$W" -o jsonpath='{.status.allocatable.cpu}')
REQ=$(kubectl describe node "$W" | awk '/Allocated resources/{f=1} f && /^ +cpu/{print $2; exit}')
PH=$(python3 -c "
a,r='$ALLOC','$REQ'
m=lambda v:int(v[:-1]) if v.endswith('m') else int(v)*1000
print(m(a)-m(r)-500)")
sed -e "s/requests: { cpu: \"1\", memory: 1Gi }    # = one full-size replica/requests: { cpu: \"${PH}m\", memory: 1Gi }/" \
    -e "s/limits: { cpu: \"1\", memory: 1Gi }/limits: { cpu: \"${PH}m\", memory: 1Gi }/" \
    examples/15-capacity-placeholder.yaml | kubectl apply -f - >/dev/null
kubectl -n demo rollout status deploy/capacity-placeholder --timeout=60s >/dev/null
echo "placeholder holds ${PH}m CPU; only 500m left free on the node"
kubectl -n demo delete pod real-pod --ignore-not-found --wait=true >/dev/null
T0=$(date +%s)
kubectl -n demo run real-pod --image=nginx:1.29-alpine --restart=Never --overrides='{"spec":{"containers":[{"name":"real-pod","image":"nginx:1.29-alpine","resources":{"requests":{"cpu":"2","memory":"64Mi"}}}]}}' >/dev/null
kubectl -n demo wait --for=condition=Ready pod/real-pod --timeout=120s >/dev/null
echo "2-CPU pod Ready after $(( $(date +%s) - T0 )) s"
kubectl -n demo get pods -l app=capacity-placeholder --no-headers | awk '{print "placeholder is now", $3, "(on OKE the autoscaler adds a node for it)"}'
kubectl -n demo delete pod real-pod --wait=false >/dev/null
sed -n '/^---/,$p' examples/15-capacity-placeholder.yaml | kubectl delete -f - --wait=false >/dev/null 2>&1 || true
kubectl delete priorityclass capacity-placeholder --ignore-not-found >/dev/null

step "10. Server-side validation of the new manifests"
kubectl apply --dry-run=server -f examples/11a-runtime-nodejs.yaml -f examples/11b-runtime-php-fpm.yaml \
  -f examples/11c-runtime-go.yaml -f examples/12-nonprod-wake-on-request.yaml \
  -f examples/13-nonprod-namespace-downscaler.yaml -f examples/14-keda-queue-worker-zero.yaml \
  -f examples/15-capacity-placeholder.yaml >/dev/null && echo "all manifests accepted"

if [[ "${1:-}" == "--long" ]]; then
  step "11. Idle memory after a burst (Node.js and Go), 6 minutes"
  kubectl -n demo delete -f lab/runtime-idle.yaml --ignore-not-found --wait=true >/dev/null
  kubectl apply -f lab/runtime-idle.yaml >/dev/null
  kubectl -n demo wait --for=condition=Ready pod/idle-node pod/idle-go --timeout=300s >/dev/null
  sleep 360
  for p in idle-node idle-go; do echo "-- $p"; kubectl -n demo logs "$p" | awk '{print $2, $3}' | uniq -f1; done
  kubectl -n demo delete -f lab/runtime-idle.yaml --wait=false >/dev/null
fi

step "Done"
