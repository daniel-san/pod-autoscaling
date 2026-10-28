#!/usr/bin/env bash
# Reproduces the local validation behind the reports on a kind cluster (Kubernetes 1.36.4,
# the newest GA version on OKE in Oct 2026). Needs: podman or docker, curl, python3.
#
#   ./lab/run-lab.sh            # create cluster (if needed), install add-ons, run checks
#   ./lab/run-lab.sh --delete   # delete the lab cluster
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

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
pod_of() { kubectl -n demo get pod -l "app=$1" --sort-by=.metadata.creationTimestamp \
             -o jsonpath='{.items[-1:].metadata.name}'; }
show() { kubectl -n demo get pod "$1" -o jsonpath='spec={.spec.containers[0].resources}{"\n"}actual={.status.containerStatuses[0].resources}{"\n"}restarts={.status.containerStatuses[0].restartCount} qos={.status.qosClass}{"\n"}'; }

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

step "1. Baseline workload (Burstable QoS, resizePolicy NotRequired)"
kubectl apply -f examples/01-app-deployment.yaml >/dev/null
kubectl -n demo rollout status deploy/my-app --timeout=180s >/dev/null
P=$(pod_of my-app); show "$P"

step "2. Shrink requests in place (limits untouched) -> expect restarts=0"
kubectl -n demo patch pod "$P" --subresource resize \
  -p '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"25m","memory":"64Mi"}}}]}}' >/dev/null
sleep 5; show "$P"

step "3. Changing the QoS class in place is rejected"
kubectl -n demo patch pod "$P" --subresource resize \
  -p '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"1","memory":"512Mi"}}}]}}' 2>&1 | tail -1 || true
kubectl -n demo patch pod "$P" --subresource resize \
  -p '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"500m","memory":"256Mi"}}}]}}' >/dev/null

step "4. Memory: request below usage is accepted; limit below usage is held back"
kubectl apply -f lab/memory-hog.yaml >/dev/null
kubectl -n demo wait --for=condition=Ready pod/memory-hog --timeout=120s >/dev/null; sleep 5
kubectl -n demo patch pod memory-hog --subresource resize \
  -p '{"spec":{"containers":[{"name":"hog","resources":{"requests":{"memory":"64Mi"}}}]}}' >/dev/null
kubectl -n demo patch pod memory-hog --subresource resize \
  -p '{"spec":{"containers":[{"name":"hog","resources":{"limits":{"memory":"128Mi"}}}]}}' >/dev/null
sleep 10; show memory-hog
kubectl -n demo get pod memory-hog -o jsonpath='{range .status.conditions[*]}{.type} {.reason}{"\n"}{end}' | grep -i resize || echo "no resize condition"
kubectl -n demo delete pod memory-hog --wait=false >/dev/null

step "5. VPA InPlaceOrRecreate raises an under-requested pod without restart (~1-3 min)"
kubectl apply -f lab/vpa-hamster.yaml >/dev/null
kubectl -n demo rollout status deploy/hamster --timeout=180s >/dev/null
H=$(pod_of hamster)
for _ in $(seq 1 24); do
  cpu=$(kubectl -n demo get pod "$H" -o jsonpath='{.spec.containers[0].resources.requests.cpu}')
  [[ "$cpu" != "100m" ]] && break; sleep 10
done
echo "pod $H (same pod, not recreated):"; show "$H"
kubectl -n demo delete -f lab/vpa-hamster.yaml >/dev/null

step "6. VPA CPU Startup Boost (alpha): boosted at creation, shrunk in place after Ready+30s"
kubectl apply -f examples/04-vpa-startup-boost.yaml >/dev/null; sleep 2
kubectl -n demo rollout restart deploy/my-app >/dev/null; sleep 8
P=$(pod_of my-app); echo "t+8s:"; show "$P"
sleep 45; echo "t+53s:"; show "$P"
kubectl -n demo delete -f examples/04-vpa-startup-boost.yaml >/dev/null

step "7. Schedule-based idle shrinker (CronJob), run on demand"
kubectl apply -f examples/01-app-deployment.yaml >/dev/null
kubectl -n demo rollout restart deploy/my-app >/dev/null
kubectl -n demo rollout status deploy/my-app --timeout=180s >/dev/null; sleep 5
kubectl apply -f examples/05-idle-shrinker-cronjob.yaml >/dev/null
for mode in off-hours business-hours; do
  kubectl -n demo delete job "lab-$mode" --ignore-not-found >/dev/null
  kubectl -n demo create job "lab-$mode" --from="cronjob/idle-shrinker-$mode" >/dev/null
  kubectl -n demo wait --for=condition=complete "job/lab-$mode" --timeout=180s >/dev/null
  kubectl -n demo logs "job/lab-$mode"; sleep 3; show "$(pod_of my-app)"
done

step "8. KEDA ScaledObject (cron + absolute CPU) creates the expected HPA"
kubectl apply -f examples/06-keda-cron-min-one.yaml >/dev/null; sleep 45
kubectl -n demo get hpa keda-hpa-my-app
kubectl -n demo delete -f examples/06-keda-cron-min-one.yaml >/dev/null

step "9. Server-side schema validation of the remaining manifests"
kubectl apply --dry-run=server -f examples/02-vpa-recommend-only.yaml -f examples/03-vpa-inplace.yaml \
  -f examples/07-hpa-absolute-cpu.yaml
for f in karpenter.sh_nodepools.yaml karpenter.sh_nodeclaims.yaml oci.oraclecloud.com_ocinodeclasses.yaml; do
  curl -sSL "https://raw.githubusercontent.com/oracle/karpenter-provider-oci/v1.4.0/pkg/apis/crds/$f"
  echo "---"
done | kubectl apply --server-side -f - >/dev/null
kubectl apply --dry-run=server -f examples/08-karpenter-oci-burstable-and-preemptible.yaml
python3 -c "import json; json.load(open('examples/09-oke-cluster-autoscaler-addon.json')); print('09 JSON ok')"

step "Done. Delete the cluster with: ./lab/run-lab.sh --delete"
