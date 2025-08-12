#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Tetragon on OpenShift via Isovalent Helm chart with integrated Grafana/Prometheus
# Deploy first, then grant SCC/RBAC. Explicit SA names for Grafana/Prometheus (if chart supports).
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

# Clean old temp files, then create a fresh one
find /tmp -maxdepth 1 -type f -name 'tetragon-values.*.yaml' -mtime +1 -delete 2>/dev/null || true
TMP_VALUES="$(mktemp /tmp/tetragon-values.XXXXXX.yaml)"
cleanup_tmp() { [[ -f "$TMP_VALUES" ]] && rm -f "$TMP_VALUES" && echo "[INFO] Cleaned: $TMP_VALUES"; }
trap cleanup_tmp EXIT

# ---- Helm values (monitoring enabled; explicit SA names where supported; no PV for Prometheus)
cat > "${TMP_VALUES}" <<YAML
serviceAccount:
  create: true
  name: tetragon

operator:
  enabled: true

monitoring:
  enabled: true

  prometheus:
    enabled: true
    # NOTE: Some chart versions support setting the server ServiceAccount like below.
    # If unsupported, Helm will ignore and we'll detect the actual SA post-install.
    server:
      serviceAccount:
        create: true
        name: prometheus
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
    # NOTE: Some chart versions support setting the Grafana ServiceAccount like below.
    # If unsupported, Helm will ignore and we'll detect the actual SA post-install.
    serviceAccount:
      create: true
      name: grafana
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
YAML

# Remove lingering SAs that cause Helm ownership conflicts
oc -n "${NS}" delete sa tetragon-operator-service-account --ignore-not-found
oc -n "${NS}" delete sa tetragon --ignore-not-found

echo "==> Installing/Upgrading Tetragon (with integrated Grafana & Prometheus)"
# Install first (no pre-created SAs) to avoid Helm ownership conflicts.
# Use --wait=false so we can grant SCCs before readiness is checked.
helm upgrade --install "${RELEASE}" cilium/tetragon -n "${NS}" --create-namespace \
  -f "${TMP_VALUES}" --wait=false --timeout "${HELM_TIMEOUT}"

echo "==> Post-install: resolve SAs and grant SCCs"
# Helper to fetch SA name from a deployment by label selector
get_sa_from_deploy() {
  local ns="$1" sel="$2"
  oc -n "$ns" get deploy -l "$sel" -o jsonpath='{.items[0].spec.template.spec.serviceAccountName}' 2>/dev/null || true
}

# Tetragon DS SA
DS_SA="$(oc -n "${NS}" get ds tetragon -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
[[ -n "${DS_SA}" ]] && echo "DaemonSet SA: ${DS_SA}" && oc adm policy add-scc-to-user privileged -z "${DS_SA}" -n "${NS}" >/dev/null 2>&1 || true

# Operator SA
OP_SA="$(oc -n "${NS}" get deploy tetragon-operator -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
[[ -n "${OP_SA}" ]] && echo "Operator SA: ${OP_SA}" && oc adm policy add-scc-to-user anyuid -z "${OP_SA}" -n "${NS}" >/dev/null 2>&1 || true

# Grafana SA: try explicit name, then by deployment label, then fallback by SA list
GRAFANA_SA="grafana"
if ! oc -n "${NS}" get sa "${GRAFANA_SA}" >/dev/null 2>&1; then
  GRAFANA_SA="$(get_sa_from_deploy "${NS}" "app.kubernetes.io/name=grafana")"
fi
if [[ -z "${GRAFANA_SA}" ]]; then
  GRAFANA_SA="$(oc -n "${NS}" get sa -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i '^.*grafana.*$' | head -n1 || true)"
fi
[[ -n "${GRAFANA_SA}" ]] && echo "Grafana SA: ${GRAFANA_SA}" && oc adm policy add-scc-to-user anyuid -z "${GRAFANA_SA}" -n "${NS}" >/dev/null 2>&1 || true

# Prometheus SA: try explicit name, then by deployment label, then fallback patterns
PROM_SA="prometheus"
if ! oc -n "${NS}" get sa "${PROM_SA}" >/dev/null 2>&1; then
  # Many charts label server deploy as app=prometheus or app.kubernetes.io/name=prometheus
  PROM_SA="$(get_sa_from_deploy "${NS}" "app.kubernetes.io/name=prometheus")"
  [[ -z "${PROM_SA}" ]] && PROM_SA="$(get_sa_from_deploy "${NS}" "app=prometheus")"
fi
if [[ -z "${PROM_SA}" ]]; then
  PROM_SA="$(oc -n "${NS}" get sa -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -i 'prometheus' | head -n1 || true)"
fi
[[ -n "${PROM_SA}" ]] && echo "Prometheus SA: ${PROM_SA}" && oc adm policy add-scc-to-user anyuid -z "${PROM_SA}" -n "${NS}" >/dev/null 2>&1 || true

echo "==> Ensure operator has CRD permissions (only if missing)"
if [[ -n "${OP_SA}" ]] && ! oc get clusterrolebinding tetragon-operator-crd-binding >/dev/null 2>&1; then
  cat <<YAML_RBAC | oc apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tetragon-operator-crd
rules:
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions"]
    verbs: ["get","list","watch","create","update","patch","delete"]
  - apiGroups: ["cilium.io"]
    resources: ["tracingpolicies","tracingpoliciesnamespaced"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tetragon-operator-crd-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tetragon-operator-crd
subjects:
  - kind: ServiceAccount
    name: ${OP_SA}
    namespace: ${NS}
YAML_RBAC
fi

echo "==> Restart workloads to pick up SCC/RBAC"
oc -n "${NS}" rollout restart ds/tetragon >/dev/null 2>&1 || true
oc -n "${NS}" rollout restart deploy/tetragon-operator >/dev/null 2>&1 || true

echo "==> Wait for pods to become Ready"
oc -n "${NS}" wait --for=condition=Ready pods --all --timeout=180s || true
oc -n "${NS}" get pods -o wide

echo "==> Create Grafana Route (if present)"
if ! oc -n "${NS}" get route grafana >/dev/null 2>&1; then
  GRAFANA_SVC="$(oc -n "${NS}" get svc -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${GRAFANA_SVC}" ]]; then
    oc -n "${NS}" create route edge grafana --service="${GRAFANA_SVC}" --port=service --insecure-policy=Allow >/dev/null 2>&1 || true
  fi
fi
if oc -n "${NS}" get route grafana >/dev/null 2>&1; then
  echo "Grafana URL: $(oc -n "${NS}" get route grafana -o jsonpath='https://{.spec.host}')"
  echo "Login: admin / ${GRAFANA_ADMIN_PASSWORD}"
fi

echo "==> Events (tail)"
oc -n "${NS}" get events --sort-by=.lastTimestamp | tail -n 40 || true
