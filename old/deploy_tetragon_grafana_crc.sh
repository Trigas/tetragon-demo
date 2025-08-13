#!/usr/bin/env bash
set -euo pipefail

# ---- Config
NS="${NS:-tetragon-system}"
RELEASE="${RELEASE:-tetragon}"
HELM_REPO="${HELM_REPO:-https://helm.isovalent.com}"
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$ROOT/tools"
VALUES_MAIN="$TOOLS/tetragon-values.yaml"
VALUES_TPL="$TOOLS/values-ocp.yaml"
VALUES_UID="$TOOLS/ocp-uid-overrides.yaml"

require() { command -v "$1" >/dev/null 2>&1 || { echo "[ERR] Missing $1"; exit 1; }; }
require oc; require helm; require sed

echo "==> Namespace: $NS"

# ---- Cleanup if existing
if helm -n "$NS" status "$RELEASE" >/dev/null 2>&1; then
  echo "==> Existing deployment detected — cleaning up..."
  helm -n "$NS" uninstall "$RELEASE" || true
  oc delete ns "$NS" --ignore-not-found=true
  # Delete Tetragon CRDs if present
  CRDS=$(oc get crd 2>/dev/null | awk '/tetragon|cilium|tracingpolicies/ {print $1}')
  if [[ -n "$CRDS" ]]; then
    echo "$CRDS" | xargs oc delete crd --ignore-not-found=true
  fi
  echo "==> Waiting for namespace deletion..."
  for i in {1..60}; do
    if ! oc get ns "$NS" >/dev/null 2>&1; then break; fi
    sleep 2
  done
fi

# ---- Create namespace
oc new-project "$NS" >/dev/null 2>&1 || true

# ---- Helm repo
helm repo add isovalent "$HELM_REPO" >/dev/null 2>&1 || true
helm repo update >/dev/null

# ---- Install/upgrade with main values
echo "==> Installing Tetragon (integrated Grafana)"
helm upgrade --install "$RELEASE" isovalent/tetragon \
  -n "$NS" --create-namespace \
  -f "$VALUES_MAIN" \
  --wait=false --timeout "$HELM_TIMEOUT"

# ---- Helpers
wait_exists() {
  local kind="$1" name="$2" tries="${3:-60}"
  for i in $(seq 1 "$tries"); do
    if oc -n "$NS" get "$kind" "$name" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "[WARN] $kind/$name not found after $((tries*2))s"
}

wait_min_pods_created() {
  local selector="$1" min="${2:-1}" tries="${3:-60}"
  for i in $(seq 1 "$tries"); do
    local count
    count=$(oc -n "$NS" get pods -l "$selector" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -ge "$min" ]]; then return 0; fi
    sleep 2
  done
  echo "[WARN] No pods for '$selector' after $((tries*2))s"
}

# ---- Wait for workloads
echo "==> Waiting for workloads to exist"
wait_exists ds tetragon
wait_exists deploy tetragon-operator
wait_exists deploy tetragon-grafana
wait_exists deploy tetragon-kube-state-metrics
wait_exists sts tetragon-prometheus

# ---- Wait for pods to be created
echo "==> Waiting for pods to be created"
wait_min_pods_created 'app.kubernetes.io/name=tetragon'
wait_min_pods_created 'app.kubernetes.io/name=tetragon-operator'
#wait_min_pods_created 'app.kubernetes.io/name=grafana'
#wait_min_pods_created 'app.kubernetes.io/name=prometheus'
#wait_min_pods_created 'app.kubernetes.io/name=kube-state-metrics'

# ---- Discover ServiceAccounts
get_sa() { oc -n "$NS" get "$1" "$2" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true; }
DS_SA="$(get_sa ds tetragon)"
OP_SA="$(get_sa deploy tetragon-operator)"
GF_SA="$(get_sa deploy tetragon-grafana)"
PR_SA="$(get_sa sts tetragon-prometheus)"
KS_SA="$(get_sa deploy tetragon-kube-state-metrics)"
echo "==> SAs: DS=$DS_SA OP=$OP_SA GF=$GF_SA PR=$PR_SA KS=$KS_SA"

# ---- Grant SCCs
oc adm policy add-scc-to-user privileged "system:serviceaccount:$NS:$DS_SA" || true
oc adm policy add-scc-to-user anyuid "system:serviceaccount:$NS:$DS_SA" || true
oc adm policy add-scc-to-user anyuid "system:serviceaccount:$NS:$OP_SA" || true
for SA in "$GF_SA" "$PR_SA" "$KS_SA"; do
  [[ -n "$SA" ]] && oc adm policy add-scc-to-user anyuid "system:serviceaccount:$NS:$SA" || true
done

# ---- UID override
RANGE="$(oc get ns "$NS" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' || true)"
START_UID="${RANGE%%/*}"
if [[ -n "$START_UID" && -f "$VALUES_TPL" ]]; then
  sed "s/__START_UID__/${START_UID}/g" "$VALUES_TPL" > "$VALUES_UID"
  helm upgrade --install "$RELEASE" isovalent/tetragon \
    -n "$NS" \
    -f "$VALUES_MAIN" \
    -f "$VALUES_UID" \
    --wait=false --timeout "$HELM_TIMEOUT"
fi

# ---- Clear annotations
wipe_ann() { oc -n "$NS" patch "$1" "$2" --type=merge -p '{"spec":{"template":{"metadata":{"annotations":{}}}}}' || true; }
wipe_ann deploy tetragon-grafana
wipe_ann sts tetragon-prometheus
wipe_ann deploy tetragon-kube-state-metrics

# ---- Restart
oc -n "$NS" rollout restart ds/tetragon || true
oc -n "$NS" rollout restart deploy/tetragon-operator || true
oc -n "$NS" rollout restart deploy/tetragon-grafana || true
oc -n "$NS" rollout restart sts/tetragon-prometheus || true
oc -n "$NS" rollout restart deploy/tetragon-kube-state-metrics || true

# ---- Wait ready
oc -n "$NS" wait --for=condition=Ready pods --all --timeout=180s || true
oc -n "$NS" get pods -o wide

# ---- Expose Grafana
GRAFANA_SVC=$(oc -n "$NS" get svc -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
oc -n "$NS" expose svc "$GRAFANA_SVC" || true
echo "Grafana URL: https://$(oc -n "$NS" get route "$GRAFANA_SVC" -o jsonpath='{.spec.host}')"