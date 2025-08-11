[![CRC](https://img.shields.io/badge/CRC-v4.19.x-blue)]()
[![OpenShift](https://img.shields.io/badge/OpenShift-v4.19.x-red)]()
[![Platform](https://img.shields.io/badge/Platform-macOS%20Apple%20Silicon-lightgrey)]()

# CRC + Tetragon (Isovalent) with Integrated Grafana & Prometheus

This guide deploys **Tetragon** using the **Isovalent Helm chart** with the **integrated Grafana + Prometheus** stack in **one namespace** (`tetragon-system`). No separate observability namespace.

> Fast path? Use **Quickstart.md**.

---

## Requirements
- macOS (M1/M2), CRC / `oc` / `helm`
- ~14 GB RAM & 6 vCPU free for the CRC VM
- Install jupyter-lab to use the notebook

**Access requirement** — Run install as **cluster-admin** (`kubeadmin`).

---

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

## 3) Install Tetragon (Isovalent) with **integrated Grafana + Prometheus**
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

### OpenShift SCC for Tetragon
```bash
SA=$(oc -n $NS get sa -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep tetragon | head -n1)
oc adm policy add-scc-to-user privileged -z "$SA" -n $NS
oc -n $NS rollout restart ds/tetragon || true
```

### Grafana route (same namespace)
```bash
GRAFANA_SVC=$(oc -n $NS get svc -l app.kubernetes.io/name=grafana -o name | head -n1)
oc -n $NS expose $GRAFANA_SVC || true
oc -n $NS get route -l app.kubernetes.io/name=grafana -o jsonpath='http://{.items[0].spec.host}\n'
# Login: admin / tetragon
```

## 4) Demo App (official upstream manifest)
```bash
oc new-project tetragon-demo || true
oc -n tetragon-demo apply -f https://raw.githubusercontent.com/cilium/cilium/1.18.0/examples/minikube/http-sw-app.yaml
oc -n tetragon-demo get pods,svc
```

## 5) Observe
```bash
oc -n $NS exec ds/tetragon -- tetra getevents --color always | head -n 50
```

## Cleanup
```bash
oc -n tetragon-demo delete -f https://raw.githubusercontent.com/cilium/cilium/1.18.0/examples/minikube/http-sw-app.yaml --ignore-not-found
helm uninstall tetragon -n $NS || true
oc delete project tetragon-demo --ignore-not-found
oc delete project $NS --ignore-not-found
```

---

### Notes
- The **Isovalent Tetragon** Helm chart comes from `https://helm.isovalent.com` and supports integrated Grafana/Prometheus in a single release.
- If the Grafana service label selector differs, list services to find it: `oc -n $NS get svc`.
