# Quickstart — Tetragon + Grafana + Star‑Wars on CRC (macOS)

This guide mirrors the deploy-tetragon-with-grafana.sh script   using **terminal** and **cli** only. It’s OpenShift‑safe (SCC aware) and matches your latest deployment method.

## 1) Install OpenShift Local (CRC)

CodeReady Containers (CRC) is Red Hat’s local, single-node OpenShift cluster for running and testing OpenShift on your laptop or desktop. Refer to [https://crc.dev/docs/introducing/](https://crc.dev/docs/introducing/) for information about VM requirements.

### To deploy a openshift cluster, you have two options

#### Option A — Red Hat site (recommended)

1. Sign in to your Red Hat account: [https://console.redhat.com/openshift/create/local](https://console.redhat.com/openshift/create/local)
2. Download **OpenShift Local (CRC)** for **macOS** and your **pull secret**.
3. Save your pull secret as **pull-secret.txt** in this directory.

> ⚠️ If you don't have a RH account you may use the **pull-secret.txt included in this repo**. It is for **demo use only** and must **never** be shared outside your local lab.

#### Option B — Homebrew

```bash
brew install crc
```

You still need a **pull secret** to start CRC.

Reference how‑to: [https://www.redhat.com/en/blog/codeready-containers](https://www.redhat.com/en/blog/codeready-containers)

---

## 2) Start CRC

```bash
crc setup
crc start --pull-secret-file pull-secret.txt

# (Optional) Add oc to PATH for this session
eval "$(crc oc-env)"

oc whoami
oc get nodes -o wide
```

---

## 3) Install **Tetragon** with **integrated Grafana/Prometheus** (Helm)

```bash
# Namespace & Helm repo
NS=tetragon-system
helm repo add isovalent https://helm.isovalent.com || true
helm repo update

# Install Tetragon + operator + integrated monitoring (no SCC yet)
helm upgrade --install tetragon isovalent/tetragon \
  -n $NS --create-namespace \
  --set serviceAccount.create=true \
  --set serviceAccount.name=tetragon \
  --set operator.enabled=true \
  --set integratedGrafana.enabled=true \
  --set integratedGrafana.prometheus.resources.requests.cpu=200m \
  --set integratedGrafana.prometheus.resources.requests.memory=512Mi \
  --set integratedGrafana.prometheus.resources.limits.memory=1Gi \
  --set grafana.adminPassword="tetragon" \
  --set grafana.resources.requests.cpu=50m \
  --set grafana.resources.requests.memory=128Mi \
  --set grafana.resources.limits.memory=256Mi \
  --wait=false --timeout 10m

# Show what got created
oc -n $NS get ds tetragon
oc -n $NS get deploy tetragon-operator tetragon-grafana tetragon-kube-state-metrics
oc -n $NS get sts tetragon-prometheus
```

### 3a) Grant **only the required SCCs** (no blanket anyuid)

```bash
# Tetragon DaemonSet needs eBPF/host → privileged SCC
oc adm policy add-scc-to-user privileged -z tetragon -n $NS

# Operator → anyuid SCC (name may differ; probe from deployment if needed)
OP_SA=$(oc -n $NS get deploy tetragon-operator -o jsonpath='{.spec.template.spec.serviceAccountName}')
[[ -z "$OP_SA" ]] && OP_SA=tetragon-operator-service-account
oc adm policy add-scc-to-user anyuid -z "$OP_SA" -n $NS

# Restart DS/Operator to pick up SCC
oc -n $NS rollout restart ds/tetragon || true
oc -n $NS rollout restart deploy/tetragon-operator || true
```

### 3b) **Patch UIDs** for monitoring components (Grafana/Prometheus/KSM)

On OpenShift, these workloads often need an explicit **runAsUser/fsGroup** matching the project UID.

```bash
# Discover the project’s START_UID
START_UID=$(oc get ns $NS -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' | cut -d/ -f1)
if [[ -z "$START_UID" ]]; then
  START_UID=$(oc get ns $NS -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}' | cut -d/ -f1)
fi
: "${START_UID:=1000640000}"
echo "Using START_UID=$START_UID"

# Patch Grafana
oc -n $NS patch deploy tetragon-grafana --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/securityContext\",\"value\":{\"fsGroup\":$START_UID}},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/securityContext\",\"value\":{\"runAsNonRoot\":true,\"runAsUser\":$START_UID,\"runAsGroup\":$START_UID}}
]"

# Patch kube-state-metrics
oc -n $NS patch deploy tetragon-kube-state-metrics --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/securityContext\",\"value\":{\"fsGroup\":$START_UID}},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/securityContext\",\"value\":{\"runAsNonRoot\":true,\"runAsUser\":$START_UID,\"runAsGroup\":$START_UID}}
]"

# Patch Prometheus (StatefulSet)
oc -n $NS patch sts tetragon-prometheus --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/securityContext\",\"value\":{\"fsGroup\":$START_UID}},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/securityContext\",\"value\":{\"runAsNonRoot\":true,\"runAsUser\":$START_UID,\"runAsGroup\":$START_UID}}
]"

# Restart to apply SCC/UID changes
oc -n $NS rollout restart deploy/tetragon-grafana
oc -n $NS rollout restart deploy/tetragon-kube-state-metrics
oc -n $NS rollout restart sts/tetragon-prometheus

# Wait until healthy
oc -n $NS rollout status deploy/tetragon-grafana --timeout=5m || true
oc -n $NS rollout status deploy/tetragon-kube-state-metrics --timeout=5m || true
oc -n $NS rollout status sts/tetragon-prometheus --timeout=5m || true
```

### 3c) Expose Grafana (HTTP route)

```bash
oc -n $NS expose svc tetragon-grafana --name tetragon-grafana --port=service
oc -n $NS wait route/tetragon-grafana \
  --for=jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}'=True \
  --timeout=60s || true
oc -n $NS get route tetragon-grafana -o jsonpath='{.spec.host}{"\n"}'
```

---

## 4) Deploy the **Star‑Wars** demo (upstream) + OpenShift patches

```bash
DEMO_NS=tetragon-demo
oc new-project $DEMO_NS || true

# Upstream demo
oc -n $DEMO_NS apply -f https://raw.githubusercontent.com/cilium/cilium/1.18.0/examples/minikube/http-sw-app.yaml

# Allow root for upstream demo pods (lab scope)
oc adm policy add-scc-to-user anyuid -z default -n $DEMO_NS

# Labels needed by your policy
oc -n $DEMO_NS patch deploy/deathstar --type=json -p='[
  {"op":"add","path":"/spec/template/metadata/labels/app.kubernetes.io~1part-of","value":"starwars-demo"}
]'
oc -n $DEMO_NS label pod/xwing app.kubernetes.io/part-of=starwars-demo --overwrite
oc -n $DEMO_NS label pod/tiefighter app.kubernetes.io/part-of=starwars-demo --overwrite

# Restart deathstar to propagate label to new pods
oc -n $DEMO_NS rollout restart deploy/deathstar

# Check
oc -n $DEMO_NS get pods -L org,class,app.kubernetes.io/part-of
```

---

## 5) Apply **TracingPolicy** (observe)

Policies are **cluster‑scoped** objects.

```bash
# Apply your policy from this repo
oc apply -f policies/starwars_tetra_policy.yaml

# Confirm policy exists
oc get tracingpolicies
```

Get events (two options):

```bash
# A) run tetra inside the DaemonSet
TPOD=$(oc -n $NS get pod -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].metadata.name}')
oc -n $NS exec "$TPOD" -c tetragon -- tetra getevents --namespace $DEMO_NS --follow -o compact

# B) (optional) create a Service and port-forward gRPC
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: tetragon-grpc
  namespace: $NS
spec:
  selector:
    app.kubernetes.io/name: tetragon
  ports:
    - name: grpc
      port: 54321
      targetPort: 54321
EOF
oc -n $NS port-forward svc/tetragon-grpc 54321:54321
# in another terminal:
# tetra getevents --server localhost:54321 --namespace $DEMO_NS --follow -o compact
```

Generate some activity:

```bash
oc -n $DEMO_NS exec tiefighter -- sh -c 'wget -qO- http://deathstar.$DEMO_NS.svc.cluster.local/v1/request-landing || true'
```

---

## 6) Flip from **Alerting** → **Blocking** (optional)

To demo enforcement, copy your policy and add a `Sigkill` action **(commented here for reference)**:

```yaml
# policies/starwars_tetra_policy_block.yaml (example snippet)
# ... keep your existing selectors ...
actions:
  - type: EventLog
    event:
      type: syscall
      severity: info
      message: "🚨 Empire activity detected (blocking)"
  # - type: Sigkill   # ← uncomment to kill offending process
  #   matchActions: []
```

Apply and test:

```bash
oc apply -f policies/starwars_tetra_policy_block.yaml
oc -n $DEMO_NS exec tiefighter -- sh -c 'wget -qO- http://deathstar.$DEMO_NS.svc.cluster.local/v1/request-landing || true'
```

---

## 7) Troubleshooting

- **Grafana route says “Application is not available”** → ensure service port name is `service` and pods are Ready; re‑create the Route as above.
- **No events in tetra** → verify policy loaded (`oc get tracingpolicies`), labels match (`oc -n $DEMO_NS get pods -L org,class,app.kubernetes.io/part-of`), and use *tiefighter/deathstar* (empire) for tests.
- **PSA warnings on demo pods** → expected; `anyuid` SCC was granted only to the demo namespace SA.

---

You now have CRC + Tetragon + Grafana + Star‑Wars running with **SCC‑aware UID patching** and **no blanket anyuid** on monitoring components.
