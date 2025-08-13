#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Tetragon on OpenShift (CRC) via Isovalent Helm chart with integrated Grafana
# with robust SCC handling (precreate SA, pre/post grants, restart DS)
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

# Clean very old temp files, then create a fresh one
find /tmp -maxdepth 1 -type f -name 'tetragon-values.*.yaml' -mtime +1 -delete 2>/dev/null || true
TMP_VALUES="$(mktemp /tmp/tetragon-values.XXXXXX.yaml)"
cleanup_tmp() { [[ -f "$TMP_VALUES" ]] && rm -f "$TMP_VALUES" && echo "[INFO] Cleaned: $TMP_VALUES"; }
trap cleanup_tmp EXIT

# Precreate the expected Tetragon DS ServiceAccount and grant privileged BEFORE install
echo "==> Pre-creating ServiceAccount 'tetragon' and granting SCC"
oc -n "${NS}" create sa tetragon >/dev/null 2>&1 || true
oc adm policy add-scc-to-user privileged -z tetragon -n "${NS}" >/dev/null 2>&1 || true

# Pre-grant any existing Grafana/Prometheus SAs anyuid (idempotent)
if oc -n "${NS}" get sa >/dev/null 2>&1; then
  SAS_GA=$(oc -n "${NS}" get sa -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -Ei 'grafana|prometheus' || true)
  if [[ -n "${SAS_GA}" ]]; then
    echo "==> Pre-granting anyuid to: ${SAS_GA}"
    for s in ${SAS_GA}; do oc adm policy add-scc-to-user anyuid -z "$s" -n "${NS}" >/dev/null 2>&1 || true; done
  fi
fi

# Soften PSA warnings (don't enforce restricted; OpenShift uses SCC anyway)
oc label ns "${NS}" pod-security.kubernetes.io/warn=privileged --overwrite >/dev/null 2>&1 || true
oc label ns "${NS}" pod-security.kubernetes.io/audit=privileged --overwrite >/dev/null 2>&1 || true

# Values for Helm
cat > "${TMP_VALUES}" <<YAML
serviceAccount:
  create: false
  name: tetragon

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

echo "==> Installing/Upgrading Tetragon (with integrated Grafana & Prometheus)"
helm upgrade --install "${RELEASE}" cilium/tetragon -n "${NS}" --create-namespace       -f "${TMP_VALUES}" --wait --timeout "${HELM_TIMEOUT}"

echo "==> Post-install: operator RBAC + SCC (OpenShift)"
# Operator ServiceAccount (fallback to default name if jsonpath not present yet)
OP_SA="$(oc -n "${NS}" get deploy tetragon-operator -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
[[ -z "${OP_SA}" ]] && OP_SA="tetragon-operator-service-account"
echo "Operator SA: ${OP_SA}"

# Grant SCC anyuid to operator SA (non-privileged, but needs anyuid on OCP)
oc adm policy add-scc-to-user anyuid -z "${OP_SA}" -n "${NS}" >/dev/null 2>&1 || true

# Least-privilege ClusterRole/Binding so operator can manage CRDs & Tetragon CRs
cat <<YAML | oc apply -f - >/dev/null
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
YAML

# Restart operator to pick up SCC/RBAC
oc -n "${NS}" rollout restart deploy/tetragon-operator >/dev/null 2>&1 || true

echo "==> Post-install SCC verification and grants"
# Identify actual DS service account and grant privileged if different
DS_SA="$(oc -n "${NS}" get ds tetragon -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
if [[ -n "${DS_SA}" ]]; then
  echo "DaemonSet uses SA: ${DS_SA}"
  oc adm policy add-scc-to-user privileged -z "${DS_SA}" -n "${NS}" >/dev/null 2>&1 || true
fi

# Grant anyuid to any Grafana/Prometheus SAs created by Helm
SAS_GA_POST=$(oc -n "${NS}" get sa -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -Ei 'grafana|prometheus' || true)
if [[ -n "${SAS_GA_POST}" ]]; then
  echo "Granting anyuid to: ${SAS_GA_POST}"
  for s in ${SAS_GA_POST}; do oc adm policy add-scc-to-user anyuid -z "$s" -n "${NS}" >/dev/null 2>&1 || true; done
fi

echo "==> Restarting DaemonSet to pick SCC (if needed)"
oc -n "${NS}" rollout restart ds/tetragon >/dev/null 2>&1 || true

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
