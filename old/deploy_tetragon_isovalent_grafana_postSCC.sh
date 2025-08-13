#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Tetragon on OpenShift via Isovalent Helm chart with integrated Grafana/Prometheus
# Deploy first, then set SCCs/RBAC to avoid Helm ownership conflicts
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

# ---- Helm values (integrated Grafana/Prometheus; no PV for Prometheus)
cat > "${TMP_VALUES}" <<YAML
monitoring:
  enabled: true

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
  enabled: true
YAML

echo "==> Installing/Upgrading Tetragon (with integrated Grafana & Prometheus)"
helm upgrade --install "${RELEASE}" cilium/tetragon -n "${NS}" --create-namespace -f "${TMP_VALUES}" --wait --timeout "${HELM_TIMEOUT}"

echo "==> Post-install: resolve SAs, grant SCC, and ensure operator CRD RBAC"
# Detect and grant SCC to Tetragon DS SA
DS_SA="$(oc -n "${NS}" get ds tetragon -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
if [[ -n "${DS_SA}" ]]; then
  echo "DaemonSet SA: ${DS_SA}"
  oc adm policy add-scc-to-user privileged -z "${DS_SA}" -n "${NS}" >/dev/null 2>&1 || true
fi

# Detect and grant SCC to operator SA
OP_SA="$(oc -n "${NS}" get deploy tetragon-operator -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
if [[ -n "${OP_SA}" ]]; then
  echo "Operator SA: ${OP_SA}"
  oc adm policy add-scc-to-user anyuid -z "${OP_SA}" -n "${NS}" >/dev/null 2>&1 || true

  # Add CRD RBAC if missing
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

# Grant anyuid to Grafana/Prometheus SAs
SAS_GA=$(oc -n "${NS}" get sa -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -Ei 'grafana|prometheus' || true)
if [[ -n "${SAS_GA}" ]]; then
  echo "Granting anyuid to: ${SAS_GA}"
  for s in ${SAS_GA}; do oc adm policy add-scc-to-user anyuid -z "$s" -n "${NS}" >/dev/null 2>&1 || true; done
fi

echo "==> Restarting workloads to pick up SCC changes"
oc -n "${NS}" rollout restart ds/tetragon >/dev/null 2>&1 || true
oc -n "${NS}" rollout restart deploy/tetragon-operator >/dev/null 2>&1 || true

echo "==> Waiting for pods to be Ready (120s)"
oc -n "${NS}" wait --for=condition=Ready pods --all --timeout=120s || true

echo "==> Creating Route for Grafana (if missing)"
if ! oc -n "${NS}" get route grafana >/dev/null 2>&1; then
  GRAFANA_SVC="$(oc -n "${NS}" get svc -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${GRAFANA_SVC}" ]]; then
    oc -n "${NS}" create route edge grafana --service="${GRAFANA_SVC}" --port=service --insecure-policy=Allow >/dev/null 2>&1 || true
  fi
fi
if oc -n "${NS}" get route grafana >/dev/null 2>&1; then
  echo "Grafana URL: $(oc -n "${NS}" get route grafana -o jsonpath='https://{.spec.host}')"
  echo "Login: admin / ${GRAFANA_ADMIN_PASSWORD}"
else
  echo "[WARN] Grafana Route not created (service not found)."
fi

echo "==> Final status:"
oc -n "${NS}" get pods -o wide || true
oc -n "${NS}" get events --sort-by=.lastTimestamp | tail -n 30 || true
