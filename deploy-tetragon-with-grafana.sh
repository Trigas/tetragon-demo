#!/usr/bin/env bash
set -euo pipefail

# ────────────────────────────────────────────────────────────────────────────────
# Path check — must run from repo root (demo/)
# ────────────────────────────────────────────────────────────────────────────────
if [[ ! -d "manifests" || ! -d "policies" ]]; then
  echo "❌ Please run this script from the repo root (~/demo)."
  echo "Current directory: $(pwd)"
  exit 1
fi

# ────────────────────────────────────────────────────────────────────────────────
# Mode selection
# ────────────────────────────────────────────────────────────────────────────────
DEMO_ONLY="${DEMO_ONLY:-false}"   # set to true to skip Tetragon install and run demo only

# ────────────────────────────────────────────────────────────────────────────────
# Settings (override via env)
# ────────────────────────────────────────────────────────────────────────────────
NS="${NS:-tetragon-system}"
RELEASE="${RELEASE:-tetragon}"
CHART_REPO_NAME="${CHART_REPO_NAME:-isovalent}"
CHART_REPO_URL="${CHART_REPO_URL:-https://helm.isovalent.com}"
CHART="${CHART_REPO_NAME}/tetragon"

# Expose Grafana via OpenShift Route (HTTP only)
EXPOSE_GRAFANA="${EXPOSE_GRAFANA:-true}"
GRAFANA_ROUTE_NAME="${GRAFANA_ROUTE_NAME:-tetragon-grafana}"
GRAFANA_SERVICE_NAME="${GRAFANA_SERVICE_NAME:-tetragon-grafana}"
GRAFANA_SERVICE_PORT_NAME="${GRAFANA_SERVICE_PORT_NAME:-service}"  # must match Service port name

# If CLEAN=true, script performs a full cleanup first
CLEAN="${CLEAN:-false}"

# Helm tuning for integrated stack (adjust if needed)
GRAFANA_ADMIN_PASS="${GRAFANA_ADMIN_PASS:-tetragon}"

# Timeouts
SHORT_TIMEOUT="${SHORT_TIMEOUT:-60s}"
LONG_TIMEOUT="${LONG_TIMEOUT:-5m}"

# ────────────────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────────────────
log() { printf "\n\033[1;36m[%s]\033[0m %s\n" "$(date +%H:%M:%S)" "$*"; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# Return 0 if any pod matching selector is not Ready
any_not_ready() {
  local selector="$1" ns="$2"
  local count
  count="$(oc -n "$ns" get pods -l "$selector" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${count:-0}" -eq 0 ]]; then return 0; fi
  local notready
  notready="$(oc -n "$ns" get pods -l "$selector" --no-headers \
    | awk '$2 !~ /[1-9]+\/\1/ || $3!="Running" {print $1}' || true)"
  [[ -n "$notready" ]]
}

# Extract the project’s starting UID from OpenShift annotations
get_start_uid() {
  local ns="$1" uid_range
  uid_range="$(oc get ns "$ns" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' 2>/dev/null || true)"
  if [[ -z "$uid_range" ]]; then
    local supp_range
    supp_range="$(oc get ns "$ns" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}' 2>/dev/null || true)"
    if [[ -n "$supp_range" ]]; then echo "${supp_range%%/*}"; return 0; fi
    echo "1000640000"; return 0
  fi
  echo "${uid_range%%/*}"
}

# Kind-aware wait (avoids hanging on StatefulSets)
wait_kind() { # kind name ns timeout
  local kind="$1" name="$2" ns="$3" timeout="$4"
  case "$kind" in
    deploy|deployment)
      oc -n "$ns" rollout status deployment/"$name" --timeout="$timeout"
      ;;
    ds|daemonset)
      oc -n "$ns" rollout status daemonset/"$name" --timeout="$timeout"
      ;;
    sts|statefulset)
      oc -n "$ns" rollout status statefulset/"$name" --timeout="$timeout" \
      || oc -n "$ns" wait statefulset/"$name" \
           --for=jsonpath='{.status.readyReplicas}'="$(oc -n "$ns" get sts "$name" -o jsonpath='{.spec.replicas}')" \
           --timeout="$timeout"
      ;;
    *)
      echo "Unsupported kind: $kind" >&2; return 1
      ;;
  esac
}

# Wait until a k8s object exists (not Ready)
wait_for_existence() { # kind name ns timeoutSeconds
  local kind="$1" name="$2" ns="$3" timeout="$4"
  local end=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < end )); do
    if oc -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

# JSON patch helper
patch_workload_uid() {
  local kind="$1" name="$2" ns="$3" uid="$4"
  log "Patching $kind/$name with runAsUser=$uid, fsGroup=$uid …"
  if [[ "$kind" == "deploy" || "$kind" == "deployment" ]]; then
    oc -n "$ns" patch deploy "$name" --type=json -p="[
      {\"op\":\"add\",\"path\":\"/spec/template/spec/securityContext\",\"value\":{\"fsGroup\":$uid}},
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/securityContext\",\"value\":{\"runAsNonRoot\":true,\"runAsUser\":$uid,\"runAsGroup\":$uid}}
    ]" || true
  elif [[ "$kind" == "sts" || "$kind" == "statefulset" ]]; then
    oc -n "$ns" patch sts "$name" --type=json -p="[
      {\"op\":\"add\",\"path\":\"/spec/template/spec/securityContext\",\"value\":{\"fsGroup\":$uid}},
      {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/securityContext\",\"value\":{\"runAsNonRoot\":true,\"runAsUser\":$uid,\"runAsGroup\":$uid}}
    ]" || true
  else
    fail "Unsupported kind for patch: $kind"
  fi
}

rollout_restart() {
  local kind="$1" name="$2" ns="$3"
  log "Rollout restart: $kind/$name"
  case "$kind" in
    deploy|deployment) oc -n "$ns" rollout restart deploy "$name" ;;
    ds|daemonset)      oc -n "$ns" rollout restart ds "$name" ;;
    sts|statefulset)   oc -n "$ns" rollout restart sts "$name" ;;
    *) fail "Unsupported kind for restart: $kind" ;;
  esac
}

# Create a plain HTTP route and wait for Admitted=True
expose_grafana_route_http() {
  local ns="$1" name="$2" svc="$3" port_name="$4"

  log "Creating HTTP Route '$name' → service '$svc' (port: $port_name)"
  oc -n "$ns" delete route "$name" --ignore-not-found

  oc -n "$ns" expose svc "$svc" --name "$name" --port="$port_name"

  # Wait for Admitted=True (router accepted the route)
  oc -n "$ns" wait route/"$name" \
    --for=jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}'=True \
    --timeout=60s >/dev/null 2>&1 || {
      log "Route not admitted yet; details:"
      oc -n "$ns" get route "$name" -o yaml | sed -n '1,120p' || true
    }

  local host
  host="$(oc -n "$ns" get route "$name" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "$host" ]]; then
    log "Grafana route ready → http://${host}"
  else
    log "Route created, but no host resolved yet."
  fi
}

# ────────────────────────────────────────────────────────────────────────────────
# Preconditions
# ────────────────────────────────────────────────────────────────────────────────
cmd_exists oc    || fail "oc not found in PATH"
cmd_exists helm  || fail "helm not found in PATH"

if [[ "$DEMO_ONLY" != "true" ]]; then
    # ────────────────────────────────────────────────────────────────────────────────
    # Optional: Full cleanup
    # ────────────────────────────────────────────────────────────────────────────────
    if [[ "$CLEAN" == "true" ]]; then
    log "Full cleanup of $NS"
    helm -n "$NS" uninstall "$RELEASE" || true
    oc delete ns "$NS" --ignore-not-found=true || true
    oc delete crd tracingpolicies.cilium.io --ignore-not-found=true || true
    oc delete crd tracingpolicies.namespaced.cilium.io --ignore-not-found=true || true
    oc get ns "$NS" -o name 2>/dev/null || echo "✅ Namespace gone"
    oc get crd | egrep 'tracingpolicies(\.namespaced)?\.cilium\.io' || echo "✅ No Tetragon CRDs"
    fi

    # ────────────────────────────────────────────────────────────────────────────────
    # Namespace + Helm repo
    # ────────────────────────────────────────────────────────────────────────────────
    log "Creating namespace $NS (if missing)"
    oc new-project "$NS" >/dev/null 2>&1 || true

    log "Ensuring Helm repo $CHART_REPO_NAME → $CHART_REPO_URL"
    helm repo add "$CHART_REPO_NAME" "$CHART_REPO_URL" >/dev/null 2>&1 || true
    helm repo update >/dev/null

    log "Sanity check – tetragon chart:"
    helm search repo "$CHART" || true

    # ────────────────────────────────────────────────────────────────────────────────
    # Install Tetragon (operator + integrated Grafana/Prometheus)
    # ────────────────────────────────────────────────────────────────────────────────
    log "Installing/Upgrading Tetragon with operator + integrated Grafana/Prometheus (no SCC yet)"
    helm upgrade --install "$RELEASE" "$CHART" \
    -n "$NS" --create-namespace \
    --set serviceAccount.create=true \
    --set serviceAccount.name=tetragon \
    --set operator.enabled=true \
    --set integratedGrafana.enabled=true \
    --set integratedGrafana.prometheus.resources.requests.cpu=200m \
    --set integratedGrafana.prometheus.resources.requests.memory=512Mi \
    --set integratedGrafana.prometheus.resources.limits.memory=1Gi \
    --set grafana.adminPassword="$GRAFANA_ADMIN_PASS" \
    --set grafana.resources.requests.cpu=50m \
    --set grafana.resources.requests.memory=128Mi \
    --set grafana.resources.limits.memory=256Mi \
    --wait=false --timeout 10m

    # ────────────────────────────────────────────────────────────────────────────────
    # Grant SCC to Tetragon DS + Operator only (NOT grafana/prom/ksm)
    # ────────────────────────────────────────────────────────────────────────────────
    log "Granting SCC to Tetragon components"
    oc adm policy add-scc-to-user privileged -z tetragon -n "$NS" || true

    OP_SA="tetragon-operator-service-account"
    if ! oc -n "$NS" get sa "$OP_SA" >/dev/null 2>&1; then
    if oc -n "$NS" get deploy tetragon-operator >/dev/null 2>&1; then
        OP_SA="$(oc -n "$NS" get deploy tetragon-operator -o jsonpath='{.spec.template.spec.serviceAccountName}')"
        [[ -z "$OP_SA" ]] && OP_SA="tetragon-operator-service-account"
    fi
    fi
    oc adm policy add-scc-to-user anyuid -z "$OP_SA" -n "$NS" || true

    # Ensure DS/Operator pick up SCC immediately
    if oc -n "$NS" get ds tetragon >/dev/null 2>&1; then
    rollout_restart ds tetragon "$NS"
    fi
    if oc -n "$NS" get deploy tetragon-operator >/dev/null 2>&1; then
    rollout_restart deploy tetragon-operator "$NS"
    fi

    # ────────────────────────────────────────────────────────────────────────────────
    # Patch monitoring stack early → restart → wait healthy
    # ────────────────────────────────────────────────────────────────────────────────
    START_UID="$(get_start_uid "$NS")"
    log "Using project START_UID=$START_UID for UID patches"

    # Give Helm a moment to create objects
    sleep 5

    # Patch immediately when resources show up (OpenShift often needs UID before pods go Ready)
    if wait_for_existence deploy tetragon-grafana "$NS" 180; then
    patch_workload_uid deploy tetragon-grafana "$NS" "$START_UID"
    rollout_restart   deploy tetragon-grafana "$NS"
    fi

    if wait_for_existence deploy tetragon-kube-state-metrics "$NS" 180; then
    patch_workload_uid deploy tetragon-kube-state-metrics "$NS" "$START_UID"
    rollout_restart   deploy tetragon-kube-state-metrics "$NS"
    fi

    if wait_for_existence sts tetragon-prometheus "$NS" 180; then
    patch_workload_uid sts tetragon-prometheus "$NS" "$START_UID"
    rollout_restart   sts  tetragon-prometheus "$NS"
    fi

    # Final waits (kind-aware)
    wait_kind deployment  tetragon-grafana            "$NS" "$LONG_TIMEOUT" || true
    wait_kind deployment  tetragon-kube-state-metrics "$NS" "$LONG_TIMEOUT" || true
    wait_kind daemonset   tetragon                    "$NS" "$LONG_TIMEOUT" || true
    wait_kind deployment  tetragon-operator           "$NS" "$LONG_TIMEOUT" || true
    wait_kind statefulset tetragon-prometheus         "$NS" "$LONG_TIMEOUT" || true


    # Expose Grafana via HTTP Route (optional)
    if [[ "$EXPOSE_GRAFANA" == "true" ]]; then
    if oc -n "$NS" get svc "$GRAFANA_SERVICE_NAME" >/dev/null 2>&1; then
        expose_grafana_route_http "$NS" "$GRAFANA_ROUTE_NAME" "$GRAFANA_SERVICE_NAME" "$GRAFANA_SERVICE_PORT_NAME"
    else
        log "Grafana Service '$GRAFANA_SERVICE_NAME' not found; skipping route."
    fi
    fi

    # ────────────────────────────────────────────────────────────────────────────────
    # Summary
    # ────────────────────────────────────────────────────────────────────────────────
    log "Deployment status:"
    oc -n "$NS" get ds tetragon || true
    oc -n "$NS" get deploy tetragon-operator tetragon-grafana tetragon-kube-state-metrics || true
    oc -n "$NS" get sts tetragon-prometheus || true

    log "Pods:"
    oc -n "$NS" get pods -o wide | egrep 'tetragon|grafana|prometheus|kube-state-metrics' || true

    log "Done. You can now: oc -n $NS get pods -w | egrep 'grafana|prometheus|kube-state-metrics|tetragon'"
fi
# ────────────────────────────────────────────────────────────────────────────────
# Star‑Wars demo (upstream) + OpenShift patches + TracingPolicy
# ────────────────────────────────────────────────────────────────────────────────
DEMO_NS="${DEMO_NS:-tetragon-demo}"
TRACE_YAML="${TRACE_YAML:-policies/starwars-observe-syscalls.yaml}"
STARWARS_URL="${STARWARS_URL:-https://raw.githubusercontent.com/cilium/cilium/1.18.0/examples/minikube/http-sw-app.yaml}"
DEMO_LABEL_KEY="app.kubernetes.io/part-of"
DEMO_LABEL_VAL="starwars-demo"

log "Deploying Star‑Wars demo from upstream: $STARWARS_URL"
oc new-project "$DEMO_NS" >/dev/null 2>&1 || true
oc -n "$DEMO_NS" apply -f "$STARWARS_URL"

# Upstream uses the *default* SA; pods run as UID 0 → needs anyuid on OpenShift.
log "Granting anyuid SCC to ServiceAccount 'default' in $DEMO_NS (lab scope)"
oc adm policy add-scc-to-user anyuid -z default -n "$DEMO_NS" || true

# Add the policy label your TracingPolicy expects.
# 1) Ensure deathstar Deployment template gets the label (new pods inherit it)
log "Adding ${DEMO_LABEL_KEY}=${DEMO_LABEL_VAL} to deathstar pod template"
oc -n "$DEMO_NS" patch deploy/deathstar --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/template/metadata/labels/${DEMO_LABEL_KEY//\//~1}\",\"value\":\"${DEMO_LABEL_VAL}\"}
]" || true

# 2) Label current one-off pods (xwing / tiefighter)
oc -n "$DEMO_NS" label pod/xwing      ${DEMO_LABEL_KEY}=${DEMO_LABEL_VAL} --overwrite || true
oc -n "$DEMO_NS" label pod/tiefighter ${DEMO_LABEL_KEY}=${DEMO_LABEL_VAL} --overwrite || true

# 3) Restart deathstar to ensure new ReplicaSet/pods carry the label
oc -n "$DEMO_NS" rollout restart deploy/deathstar || true

# Wait for demo to be up
log "Waiting for demo workloads to be Ready"
oc -n "$DEMO_NS" rollout status deploy/deathstar --timeout=3m || true
oc -n "$DEMO_NS" get pods -o wide | egrep 'deathstar|xwing|tiefighter' || true

# Apply your TracingPolicy
if [[ -f "$TRACE_YAML" ]]; then
  log "Applying TracingPolicy: $TRACE_YAML"
  oc apply -f "$TRACE_YAML"
else
  log "TracingPolicy file not found at $TRACE_YAML — skipping (set TRACE_YAML to override)."
fi

# Apply port-forward to Tetragon gRPC
log "Setting up port-forward to Tetragon gRPC for demo use (localhost:54321)"
echo "⏳ Waiting for Tetragon DaemonSet to become ready..."
oc -n tetragon-system rollout status ds/tetragon --timeout=180s

echo "🔌 Starting port-forward to Tetragon gRPC (localhost:54321)..."
TETRAGON_POD=$(oc -n tetragon-system get pod -l app.kubernetes.io/name=tetragon \
  -o jsonpath='{.items[0].metadata.name}')

oc -n tetragon-system port-forward pod/$TETRAGON_POD 54321:54321 &
PF_PID=$!
echo "➡️ Port-forward started (PID $PF_PID). Use 'kill $PF_PID' to stop it."


cat <<'EOS'
--------------------------------------------------------------------------------
Star‑Wars demo ready. Try:
  oc exec -n tetragon-demo xwing -- curl -s -XPOST deathstar.tetragon-demo.svc.cluster.local/v1/request-landing
  oc exec -n tetragon-demo tiefighter -- curl -s -XPOST deathstar.tetragon-demo.svc.cluster.local/v1/request-landing
  oc exec -n tetragon-demo xwing -- curl -s -XPUT -H "X-Has-Force: true" http://deathstar.tetragon-demo.svc.cluster.local/v1/exhaust-port

  # test  SSH blocking (should timeout/fail)
  oc exec -n tetragon-demo xwing -- curl -v --connect-timeout 2 deathstar.tetragon-demo.svc.cluster.local:22

  #test file access control

Watch Tetragon events:
  oc -n tetragon-system logs ds/tetragon -c tetragon -f | grep -E 'execve|process|network|Empire activity'
EOS