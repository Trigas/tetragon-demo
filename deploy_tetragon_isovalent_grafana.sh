#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Tetragon on OpenShift (CRC) via Isovalent Helm chart with integrated Grafana
#
# - Installs/updates the official cilium/tetragon Helm chart
# - Enables integrated Grafana and Prometheus (no PV for Prometheus)
# - Applies OpenShift SCCs:
#     * Tetragon DaemonSet SA  -> privileged
#     * Grafana + Prometheus SAs -> anyuid
# - Sets conservative memory requests/limits to avoid OOM / scheduling failures
# - Creates an OpenShift Route for Grafana
#
# Assumptions:
#   * You have 'oc' logged into your CRC/OpenShift cluster
#   * Helm repo 'cilium' will be added/updated by this script
#
# Notes:
#   * Tetragon tracing policies can be applied AFTER this deployment.
#   * Prometheus runs without a PersistentVolume (ephemeral storage).
# ----------------------------------------------------------------------------
set -euo pipefail

NS="${NS:-tetragon-system}"
RELEASE="${RELEASE:-tetragon}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"

echo "==> Namespace: ${NS}"
oc new-project "${NS}" >/dev/null 2>&1 || echo "Namespace ${NS} already exists."

echo "==> Adding/Updating Helm repo: cilium"
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update >/dev/null

# Create temp file
TMP_VALUES="$(mktemp /tmp/tetragon-values.XXXXXX.yaml)"

# Ensure temp file is removed on exit or error
cleanup_tmp() {
    if [[ -f "$TMP_VALUES" ]]; then
        rm -f "$TMP_VALUES"
        echo "[INFO] Cleaned up temp file: $TMP_VALUES"
    fi
}
trap cleanup_tmp EXIT

# Create the values file for Tetragon with integrated Grafana and Prometheus
cat > "${TMP_VALUES}" <<YAML
# Ref: cilium/tetragon chart values (integrated Prometheus + Grafana)
prometheus:
  enabled: true
  server:
    persistentVolume:
      enabled: false
    retention: 2h
    extraArgs:
      - --storage.tsdb.retention.time=2h
      - --storage.tsdb.wal-compression
      - --query.max-concurrency=10
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: "1"
        memory: 1Gi
  alertmanager:
    enabled: false
  pushgateway:
    enabled: false
  serviceMonitor:
    enabled: true

grafana:
  enabled: true
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
  defaultDashboardsEnabled: true
  grafana.ini:
    server:
      root_url: "%(protocol)s://%(domain)s/"
  service:
    type: ClusterIP
    port: 3000
  persistence:
    enabled: false
  resources:
    requests:
      cpu: 100m
      memory: 192Mi
    limits:
      cpu: "500m"
      memory: 512Mi

tetragon:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: "1"
      memory: 384Mi

operator:
  enabled: false
YAML

# Replace the password placeholder in the values file
sed -i.bak "s|\${GRAFANA_ADMIN_PASSWORD}|${GRAFANA_ADMIN_PASSWORD}|g" "${TMP_VALUES}"

echo "==> Preparing SCCs for Tetragon, Grafana, and Prometheus"

# Make sure namespace exists
oc new-project "${NS}" >/dev/null 2>&1 || true

# Preemptively grant SCCs even if SAs don't yet exist (Helm will create them)
# Tetragon needs privileged
for s in $(oc -n "${NS}" get sa -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^tetragon(|-daemonset|-agent)?$' || true); do
  echo "Granting privileged to $s"
  oc adm policy add-scc-to-user privileged -z "$s" -n "${NS}" || true
done

# Grafana & Prometheus need anyuid
for s in $(oc -n "${NS}" get sa -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -Ei 'grafana|prometheus' || true); do
  echo "Granting anyuid to $s"
  oc adm policy add-scc-to-user anyuid -z "$s" -n "${NS}" || true
done

# Also set PSA labels to avoid noisy warnings (optional)
oc label ns "${NS}" pod-security.kubernetes.io/warn=privileged --overwrite >/dev/null 2>&1 || true
oc label ns "${NS}" pod-security.kubernetes.io/audit=privileged --overwrite >/dev/null 2>&1 || true

echo "==> Installing/Upgrading Tetragon (with integrated Grafana & Prometheus)"
helm upgrade --install "${RELEASE}" cilium/tetragon -n "${NS}" --create-namespace       -f "${TMP_VALUES}" --wait --timeout "${HELM_TIMEOUT}"

echo "==> Applying SCCs"
# Tetragon uses a DaemonSet with a service account; grant 'privileged' for eBPF access
TETRA_SAS=$(oc -n "${NS}" get sa -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E 'tetragon|tetragon-daemonset|tetragon-agent' || true)
for SA in ${TETRA_SAS}; do
  echo "  - Granting 'privileged' to SA ${SA}"
  oc adm policy add-scc-to-user privileged -z "${SA}" -n "${NS}" >/dev/null 2>&1 || true
done

# Grafana & Prometheus often need anyuid on OpenShift depending on chart defaults
for SA in $(oc -n "${NS}" get sa -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -Ei 'grafana|prometheus'); do
  echo "  - Granting 'anyuid' to SA ${SA}"
  oc adm policy add-scc-to-user anyuid -z "${SA}" -n "${NS}" >/dev/null 2>&1 || true
done

echo "==> Restarting Tetragon DS to pick up SCC (if needed)"
oc -n "${NS}" rollout restart ds -l app.kubernetes.io/name=tetragon || true

echo "==> Waiting for pods to be ready"
oc -n "${NS}" wait --for=condition=Ready pods --all --timeout=300s || true

echo "==> Creating/OpenShift Route for Grafana (if not exists)"
# Find Grafana service name (from the helm release) and create a Route
GRAFANA_SVC=$(oc -n "${NS}" get svc -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "${GRAFANA_SVC}" ]; then
  if ! oc -n "${NS}" get route grafana >/dev/null 2>&1; then
    oc -n "${NS}" create route edge grafana --service="${GRAFANA_SVC}" --port=service --insecure-policy=Allow >/dev/null
  fi
  GRAFANA_URL=$(oc -n "${NS}" get route grafana -o jsonpath='https://{.spec.host}')
  echo "Grafana Route: ${GRAFANA_URL}"
  echo "Login with -> admin / ${GRAFANA_ADMIN_PASSWORD}"
else
  echo "WARN: Could not auto-detect Grafana service to create a Route."
fi

echo "==> Done. Notes:"
cat <<EOF
- Namespace: ${NS}
- Helm release: ${RELEASE}
- Prometheus storage: Ephemeral (no PV)
- Prometheus retention: 2h (tune in values if you need more)
- Tetragon tracing policies: apply after deployment (kubectl/oc apply -f ...)

Quick checks:
  oc -n ${NS} get pods -o wide
  oc -n ${NS} get svc
  oc -n ${NS} get route grafana

If Prometheus still fails to schedule on CRC:
  * Increase CRC memory, or
  * Reduce Prometheus resources in the values file

EOF
