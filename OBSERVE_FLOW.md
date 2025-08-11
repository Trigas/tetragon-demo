# Observe & Enforce (label-based, no Cilium required)

## Tail events
```bash
oc -n tetragon-system exec ds/tetragon -- tetra getevents --namespace tetragon-demo --color always
```

## Apply policies
```bash
oc apply -f policies/landing-attempts.yaml
oc -n tetragon-demo label pod -l app=tiefighter allow-landing=true --overwrite
oc apply -f policies/deny-landing-unlabeled.yaml
```

## Test
```bash
oc exec -n tetragon-demo xwing -- curl -s -S -XPOST deathstar.tetragon-demo.svc.cluster.local/v1/request-landing || echo "xwing blocked ✅"
oc exec -n tetragon-demo tiefighter -- curl -s -S -XPOST deathstar.tetragon-demo.svc.cluster.local/v1/request-landing | head -n1
```

## Alert
```bash
oc apply -f alerts/xwing-landing-alert.yaml
```

## Grafana
Import `grafana/starwars_landing_dashboard.json` and select your Prometheus datasource.
