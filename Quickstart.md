# Quickstart — Tetragon (Isovalent) + Integrated Grafana (CRC)

**One namespace (`tetragon-system`)**. Install as `kubeadmin`. Commands are idempotent.

## 1) Start & Login
```bash
crc setup
crc start --memory 14336 --cpus 6
eval $(crc oc-env)
oc login -u kubeadmin -p "$(cat ~/.crc/machines/crc/kubeadmin-password)" https://api.crc.testing:6443
oc whoami
```

## 2) Namespace
```bash
NS=tetragon-system
oc new-project $NS || true
```

## 3) Tetragon + integrated Grafana/Prometheus
```bash
helm repo add isovalent https://helm.isovalent.com || true
helm repo update

helm upgrade --install tetragon isovalent/tetragon -n $NS \
  --set tetragon.securityContext.privileged=true \
  --set tetragon.hostNetwork=true \
  --set tetragon.grpc.enabled=true \
  --set tetragon.grpc.address="0.0.0.0:54321" \
  --set tetragon.prometheus.enabled=true \
  --set tetragon.prometheus.port=2112 \
  --set integratedGrafana.enabled=true \
  --set integratedGrafana.prometheus.resources.requests.cpu=200m \
  --set integratedGrafana.prometheus.resources.requests.memory=512Mi \
  --set integratedGrafana.prometheus.resources.limits.memory=1Gi \
  --set grafana.resources.requests.cpu=50m \
  --set grafana.resources.requests.memory=128Mi \
  --set grafana.resources.limits.memory=256Mi \
  --set kubeStateMetrics.resources.requests.cpu=10m \
  --set kubeStateMetrics.resources.requests.memory=32Mi \
  --set kubeStateMetrics.resources.limits.memory=64Mi \
  --set grafana.adminPassword="tetragon" \
  --wait --timeout 20m
```

## 4) OpenShift SCC + Grafana route
```bash
SA=$(oc -n $NS get sa -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep tetragon | head -n1)
oc adm policy add-scc-to-user privileged -z "$SA" -n $NS
oc -n $NS rollout restart ds/tetragon || true

GRAFANA_SVC=$(oc -n $NS get svc -l app.kubernetes.io/name=grafana -o name | head -n1)
oc -n $NS expose $GRAFANA_SVC || true
oc -n $NS get route -l app.kubernetes.io/name=grafana -o jsonpath='http://{.items[0].spec.host}\n'
# Login: admin / tetragon
```

## 5) Demo app (official upstream)
```bash
oc new-project tetragon-demo || true
oc -n tetragon-demo apply -f https://raw.githubusercontent.com/cilium/cilium/1.18.0/examples/minikube/http-sw-app.yaml
oc -n tetragon-demo get pods,svc
```

## 6) Observe & Cleanup
```bash
oc -n $NS exec ds/tetragon -- tetra getevents --color always | head -n 50

oc -n tetragon-demo delete -f https://raw.githubusercontent.com/cilium/cilium/1.18.0/examples/minikube/http-sw-app.yaml --ignore-not-found
helm uninstall tetragon -n $NS || true
oc delete project tetragon-demo --ignore-not-found
oc delete project $NS --ignore-not-found
```
