#!/usr/bin/env zsh
# CRC + Tetragon + Demo health check (read-only, fast)
# Usage: ./crchealth.zsh [--details] [--debug]
# Env overrides:
#   TETRAGON_NS=tetragon-system  DEMO_NS=tetragon-demo
#   TETRAGON_DS=tetragon         DEMO_SVC=deathstar
#   DEMO_TEST_POD=secret-test

set -u
set -o pipefail

# ------------------ options ------------------
DETAILS=false
DEBUG=false
for arg in "$@"; do
  case "$arg" in
    --details) DETAILS=true ;;
    --debug)   DEBUG=true ;;
  esac
done
$DEBUG && set -x

[[ -f ~/.zshrc ]] && source ~/.zshrc

# ------------------ config -------------------
: ${TETRAGON_NS:="tetragon-system"}
: ${DEMO_NS:="tetragon-demo"}
: ${TETRAGON_DS:="tetragon"}
: ${DEMO_SVC:="deathstar"}
: ${DEMO_TEST_POD:="secret-test"}
CRD_TRACE="tracingpolicies.cilium.io"

OK="✅"; BAD="❌"; WARN="⚠️"; INFO="ℹ️"
say()  { print -r -- "$@"; }
ok()   { say "$OK  $1"; }
bad()  { say "$BAD  $1"; }
warn() { say "$WARN $1"; }
info() { say "$INFO $1"; }

START_EPOCH=$EPOCHSECONDS
fail_reasons=()   # collect reasons to drive debug dump later

# Small helper: run oc with a short timeout to avoid hangs (uses bash/zsh `timeout` if present)
_oc() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 6s oc "$@"
  else
    oc "$@"
  fi
}

# ---------------- ensure oc + login ----------------
if ! command -v oc >/dev/null 2>&1; then
  info "'oc' not in PATH. Trying 'crcdev'…"
  if command -v crcdev >/dev/null 2>&1; then crcdev >/dev/null 2>&1 || true; fi
fi
if ! command -v oc >/dev/null 2>&1; then
  bad "'oc' still missing. Install/export oc."; exit 2
fi

if ! _oc whoami >/dev/null 2>&1; then
  info "Not logged in. Trying 'crcdev'…"
  if command -v crcdev >/dev/null 2>&1; then crcdev >/dev/null 2>&1 || true; fi
fi
if ! _oc whoami >/dev/null 2>&1; then
  bad "Still not logged in. Run 'crc start' / 'oc login'."; exit 2
fi
ok "Connected as $(_oc whoami 2>/dev/null)"

# --------------- NODES (single call) ---------------
nodes_out="$(_oc get nodes --no-headers 2>/dev/null || true)"
TOTAL_NODES=$(print -r -- "$nodes_out" | wc -l | tr -d ' ')
READY_NODES=$(print -r -- "$nodes_out" | awk '{print $2}' | grep -c '^Ready' || echo 0)
if [[ "$TOTAL_NODES" -gt 0 && "$READY_NODES" -eq "$TOTAL_NODES" ]]; then
  ok "Nodes Ready: $READY_NODES/$TOTAL_NODES"
else
  warn "Nodes Ready: $READY_NODES/$TOTAL_NODES"
  fail_reasons+=("nodes")
fi

# --------------- NAMESPACES (batch-ish) ------------
ns_all="$(_oc get ns -o name 2>/dev/null || true)"
if print -r -- "$ns_all" | grep -q "^namespace/$TETRAGON_NS$"; then
  ok "Namespace: $TETRAGON_NS"
else
  bad "Missing namespace: $TETRAGON_NS"; fail_reasons+=("ns-$TETRAGON_NS")
fi
if print -r -- "$ns_all" | grep -q "^namespace/$DEMO_NS$"; then
  ok "Namespace: $DEMO_NS"
else
  warn "Missing namespace: $DEMO_NS"; fail_reasons+=("ns-$DEMO_NS")
fi

# --------------- CRD -------------------------------
if _oc get crd "$CRD_TRACE" >/dev/null 2>&1; then
  ok "CRD present: $CRD_TRACE"
else
  bad "CRD missing: $CRD_TRACE"; fail_reasons+=("crd")
fi

# --------------- TETRAGON DS (if exists) -----------
if _oc -n "$TETRAGON_NS" get ds "$TETRAGON_DS" >/dev/null 2>&1; then
  ds_json="$(_oc -n "$TETRAGON_NS" get ds "$TETRAGON_DS" -o json 2>/dev/null || true)"
  DESIRED=$(print -r -- "$ds_json" | sed -n 's/.*"desiredNumberScheduled":[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
  READY=$(  print -r -- "$ds_json" | sed -n 's/.*"numberReady":[[:space:]]*\([0-9]\+\).*/\1/p' | head -1)
  [[ -z "$DESIRED" ]] && DESIRED=0; [[ -z "$READY" ]] && READY=0
  if [[ "$DESIRED" -gt 0 && "$DESIRED" -eq "$READY" ]]; then
    ok "Tetragon DS '$TETRAGON_DS' Ready: $READY/$DESIRED"
  else
    warn "Tetragon DS '$TETRAGON_DS' Ready: $READY/$DESIRED"
    fail_reasons+=("ds")
  fi
else
  info "DaemonSet '$TETRAGON_DS' not found (OK if operator deploys agent directly)."
fi

# --------------- TETRAGON AGENT PODS ----------------
# Try CRC label first, fallback to classic
SEL_AGENT1='app.kubernetes.io/component=agent'
SEL_AGENT2='k8s-app=tetragon'
agent_selector=""
pods_json="$(_oc -n "$TETRAGON_NS" get pods -o json 2>/dev/null || true)"

if print -r -- "$pods_json" | grep -q "\"$SEL_AGENT1\""; then
  agent_selector="$SEL_AGENT1"
elif print -r -- "$pods_json" | grep -q "\"$SEL_AGENT2\""; then
  agent_selector="$SEL_AGENT2"
fi

if [[ -n "$agent_selector" ]]; then
  agent_json="$(_oc -n "$TETRAGON_NS" get pods -l "$agent_selector" -o json 2>/del/null || _oc -n "$TETRAGON_NS" get pods -l "$agent_selector" -o json 2>/dev/null || true)"
  # Count total + ready by parsing "ready" status fields
  total=$(print -r -- "$agent_json" | grep -c '"name":')
  ready=$(print -r -- "$agent_json" | sed -n 's/.*"ready":[[:space:]]*\(true\|false\).*/\1/p' | grep -c '^true$' || echo 0)
  # Better readiness: rely on X/Y Ready column? We don’t have it here; keep as count of ready containers == count of containers
  # Simpler: pull the short table once for human clarity
  brief="$(_oc -n "$TETRAGON_NS" get pods -l "$agent_selector" --no-headers 2>/dev/null || true)"
  pods=$(print -r -- "$brief" | wc -l | tr -d ' ')
  pods_ready=$(print -r -- "$brief" | awk '{print $2}' | awk -F/ '$1==$2{c++} END{print c+0}')
  if [[ "$pods" -gt 0 && "$pods_ready" -eq "$pods" ]]; then
    ok "Tetragon agent pods Ready: $pods_ready/$pods"
  else
    warn "Tetragon agent pods Ready: ${pods_ready:-0}/${pods:-0}"
    fail_reasons+=("agent-pods")
  fi
  if $DETAILS; then
    info "Agent pod → node:"
    _oc -n "$TETRAGON_NS" get pods -l "$agent_selector" -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true
  fi
else
  bad "No Tetragon agent pods found in $TETRAGON_NS (checked both common labels)."
  fail_reasons+=("agent-missing")
fi

# --------------- DEMO PODS (overall quick view) -----
demo_brief="$(_oc -n "$DEMO_NS" get pods --no-headers 2>/dev/null || true)"
if [[ -n "$demo_brief" ]]; then
  demo_total=$(print -r -- "$demo_brief" | wc -l | tr -d ' ')
  demo_ready=$(print -r -- "$demo_brief" | awk '{print $2}' | awk -F/ '$1==$2{c++} END{print c+0}')
  if [[ "$demo_total" -gt 0 && "$demo_ready" -eq "$demo_total" ]]; then
    ok "Demo pods Ready: $demo_ready/$demo_total"
  else
    warn "Demo pods Ready: ${demo_ready:-0}/${demo_total:-0}"
    fail_reasons+=("demo-pods")
  fi
else
  warn "Cannot list pods in $DEMO_NS"; fail_reasons+=("demo-ns")
fi

# --------------- DEMO SERVICE/ENDPOINTS -------------
if _oc -n "$DEMO_NS" get svc "$DEMO_SVC" >/dev/null 2>&1; then
  ep_count=$(_oc -n "$DEMO_NS" get endpoints "$DEMO_SVC" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  if [[ "${ep_count:-0}" -gt 0 ]]; then
    ok "Service '$DEMO_SVC' endpoints: $ep_count"
  else
    warn "Service '$DEMO_SVC' has 0 endpoints (selector mismatch / pod not Ready?)"
    fail_reasons+=("demo-endpoints")
  fi
fi

# --------------- SPECIFIC: secret-test pod -----------
if _oc -n "$DEMO_NS" get pod "$DEMO_TEST_POD" >/dev/null 2>&1; then
  phase=$(_oc -n "$DEMO_NS" get pod "$DEMO_TEST_POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  ready_tuple=$(_oc -n "$DEMO_NS" get pod "$DEMO_TEST_POD" -o jsonpath='{range .status.containerStatuses[*]}{.ready}{" "}{end}' 2>/dev/null || echo "")
  ready_count=$(print -r -- "$ready_tuple" | tr ' ' '\n' | grep -c '^true$' || echo 0)
  total_count=$(print -r -- "$ready_tuple" | tr ' ' '\n' | wc -l | tr -d ' ' || echo 0)
  if [[ "$phase" == "Running" && "$total_count" -gt 0 && "$ready_count" -eq "$total_count" ]]; then
    ok "Test pod '$DEMO_TEST_POD' Running & Ready ($ready_count/$total_count)"
  else
    warn "Test pod '$DEMO_TEST_POD' status: phase=$phase ready=$ready_count/$total_count"
    fail_reasons+=("secret-test")
  fi
  $DETAILS && info "Test pod node: $(_oc -n "$DEMO_NS" get pod "$DEMO_TEST_POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
else
  warn "Test pod not found: $DEMO_NS/$DEMO_TEST_POD"
  fail_reasons+=("secret-test-missing")
fi

# --------------- timing & summary --------------------
DUR=$(( EPOCHSECONDS - START_EPOCH ))
say ""
info "Health check completed in ${DUR}s"

# --------------- auto-debug on failure ---------------
if [[ "${#fail_reasons[@]}" -gt 0 || "$DEBUG" == true ]]; then
  say ""
  info "Debug summary (because: ${fail_reasons[*]:-"--debug"})"

  # Nodes
  if [[ " ${fail_reasons[*]} " == *" nodes "* || "$DEBUG" == true ]]; then
    say "— Nodes:"
    _oc get nodes -o wide || true
  fi

  # Tetragon agent pods
  if [[ " ${fail_reasons[*]} " == *" agent-pods "* || " ${fail_reasons[*]} " == *" agent-missing "* || "$DEBUG" == true ]]; then
    say "— Tetragon agent pods (table):"
    if [[ -n "$agent_selector" ]]; then
      _oc -n "$TETRAGON_NS" get pods -l "$agent_selector" -o wide || true
      say "— Recent agent logs (last 120 lines):"
      _oc -n "$TETRAGON_NS" logs -l "$agent_selector" --tail=120 || true
    else
      _oc -n "$TETRAGON_NS" get pods -o wide || true
    fi
  fi

  # DaemonSet detail
  if [[ " ${fail_reasons[*]} " == *" ds "* || "$DEBUG" == true ]]; then
    say "— Tetragon DS describe:"
    _oc -n "$TETRAGON_NS" describe ds "$TETRAGON_DS" || true
  fi

  # Demo pods/service
  if [[ " ${fail_reasons[*]} " == *" demo-pods "* || " ${fail_reasons[*]} " == *" demo-ns "* || "$DEBUG" == true ]]; then
    say "— Demo pods (wide):"
    _oc -n "$DEMO_NS" get pods -o wide || true
  fi
  if [[ " ${fail_reasons[*]} " == *" demo-endpoints "* || "$DEBUG" == true ]]; then
    say "— Demo service + endpoints:"
    _oc -n "$DEMO_NS" get svc "$DEMO_SVC" -o wide || true
    _oc -n "$DEMO_NS" get endpoints "$DEMO_SVC" -o wide || true
  fi

  # secret-test pod
  if [[ " ${fail_reasons[*]} " == *" secret-test "* || " ${fail_reasons[*]} " == *" secret-test-missing "* || "$DEBUG" == true ]]; then
    say "— secret-test pod describe:"
    _oc -n "$DEMO_NS" describe pod "$DEMO_TEST_POD" || true
  fi

  # CRD
  if [[ " ${fail_reasons[*]} " == *" crd "* || "$DEBUG" == true ]]; then
    say "— CRD short view:"
    _oc get crd "$CRD_TRACE" -o name || true
  fi
fi