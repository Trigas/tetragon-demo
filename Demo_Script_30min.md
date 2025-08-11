# 30-minute Demo Script — Tetragon + Integrated Grafana (CRC)

**Prep (before session):**
```bash
eval $(crc oc-env)
oc login -u kubeadmin -p "$(cat ~/.crc/machines/crc/kubeadmin-password)" https://api.crc.testing:6443
oc whoami
```

**0–5 min — Intro**
- Diagram: CRC, Tetragon DS, kube-prometheus-stack (Prom+Grafana), demo namespace

**5–10 min — Tetragon**
```bash
oc new-project tetragon-system || true
helm repo add cilium https://helm.cilium.io || true
helm repo update
helm upgrade --install tetragon cilium/tetragon -n tetragon-system --wait --timeout 10m
SA=$(oc -n tetragon-system get sa -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep tetragon | head -n1)
oc adm policy add-scc-to-user privileged -z "$SA" -n tetragon-system
oc -n tetragon-system rollout restart ds/tetragon || true
```

**10–18 min — Integrated Grafana + Prometheus**
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo update
helm upgrade --install monitor prometheus-community/kube-prometheus-stack -n tetragon-system -f monitoring_values.yaml --wait --timeout 15m
oc -n tetragon-system expose svc monitor-grafana
echo "Grafana route:"; oc -n tetragon-system get route monitor-grafana -o jsonpath='http://{.spec.host}\n'
oc apply -f grafana_tetragon_dashboard_cm.yaml
```

**18–24 min — Demo app**
```bash
oc new-project tetragon-demo || true
oc -n tetragon-demo apply -f https://raw.githubusercontent.com/cilium/cilium/1.18.0/examples/minikube/http-sw-app.yaml
oc -n tetragon-demo get pods,svc
```

**24–28 min — Observe**
```bash
oc -n tetragon-system exec ds/tetragon -- tetra getevents --color always | head -n 50
```

**28–30 min — Wrap & Cleanup (mention)**
```bash
oc -n tetragon-demo delete -f https://raw.githubusercontent.com/cilium/cilium/1.18.0/examples/minikube/http-sw-app.yaml --ignore-not-found
helm uninstall tetragon -n tetragon-system || true
helm uninstall monitor -n tetragon-system || true
oc delete project tetragon-demo --ignore-not-found
oc delete project tetragon-system --ignore-not-found
```

**Notes:**
- Grafana login is `admin / tetragon` (edit in monitoring_values.yaml)
- Sidecar auto-imports dashboard ConfigMaps with label `grafana_dashboard=1`
