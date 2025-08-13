#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Tetragon on OpenShift (CRC) via Isovalent Helm chart with integrated Grafana
# Pre-create SAs + SCC before Helm; monitoring.grafana/prometheus; conditional CRD RBAC
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

# Soften PSA warnings (OpenShift uses SCC, this just quiets logs)
oc label ns "${NS}" pod-security.kubernetes.io/warn=privileged  --overwrite >/dev/null 2>&1 || true
oc label ns "${NS}" pod-security.kubernetes.io/audit=privileged --overwrite >/dev/null 2>&1 || true

echo "==> Pre-create ServiceAccounts and grant SCC (to avoid pod churn)"
# Pre-create SA for Tetragon DS and Operator so we can grant SCC before pods start
oc -n "${NS}" create sa tetragon >/dev/null 2>&1 || true
oc -n "${NS}" create sa tetragon-operator-service-account >/dev/null 2>&1 || true

# Grant SCCs up-front
oc adm policy add-scc-to-user privileged -z tetragon -n "${NS}" >/dev/null 2>&1 || true
oc adm policy add-scc-to-user anyuid    -z tetragon-operator-service-account -n "${NS}" >/dev/null 2>&1 || true

# ---- Helm values (integrated Grafana/Prometheus under monitoring; no PV for Prometheus)
cat > "${TMP_VALUES}" <<YAML
# Use pre-created SAs to avoid Helm ownership conflicts & schedule with SCC from the start
serviceAccount:
  create: false
  name: tetragon

operator:
  enabled: true
  serviceAccount:
    create: false
    name: tetragon-operator-service-account

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
YAML

echo "==> Installing/Upgrading Tetragon (with integrated Grafana & Prometheus)"
helm upgrade --install "${RELEASE}" cilium/tetragon -n "${NS}" --create-namespace \
  -f "${TMP_VALUES}" --wait --timeout "${HELM_TIMEOUT}"

echo "==> Post-install: ensure operator CRD RBAC and verify SCCs"

# Resolve SAs (Helm may still rename; fetch actual names)
DS_SA="$(oc -n "${NS}" get ds tetragon -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
OP_SA="$(oc -n "${NS}" get deploy tetragon-operator -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
echo "DaemonSet SA: ${DS_SA:-tetragon}"
echo "Operator SA:  ${OP_SA:-tetragon-operator-service-account}"

# Re-assert SCCs on actual SAs (idempotent)
[[ -n "${DS_SA}" ]] && oc adm policy add-scc-to-user privileged -z "${DS_SA}" -n "${NS}" >/dev/null 2>&1 || true
[[ -n "${OP_SA}" ]] && oc adm policy add-scc-to-user anyuid    -z "${OP_SA}" -n "${NS}" >/dev/null 2>&1 || true

# Also grant anyuid to Grafana/Prometheus SAs if present
SAS_GA=$(oc -n "${NS}" get sa -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -Ei 'grafana|prometheus' || true)
if [[ -n "$SAS_GA" ]]; then
  for s in $SAS_GA; do
    oc adm policy add-scc-to-user anyuid -z "$s" -n "${NS}" >/dev/null 2>&1 || true
  done
fi

# Ensure operator has CRD permissions (only create if missing)
if ! oc get clusterrolebinding tetragon-operator-crd-binding >/dev/null 2>&1; then
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
    name: ${OP_SA:-tetragon-operator-service-account}
    namespace: ${NS}
YAML
fi

# Restart workloads to pick up SCC/RBAC if needed
oc -n "${NS}" rollout restart ds/tetragon >/dev/null 2>&1 || true
oc -n "${NS}" rollout restart deploy/tetragon-operator >/dev/null 2>&1 || true

# Wait & show status
oc -n "${NS}" wait --for=condition=Ready pods --all --timeout=180s || true
oc -n "${NS}" get pods -o wide
oc -n "${NS}" get events --sort-by=.lastTimestamp | tail -n 30 || true

# Create a Route for Grafana (if present)
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