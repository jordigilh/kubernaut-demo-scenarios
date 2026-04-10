#!/usr/bin/env bash
# Inject invalid config to cause all 5 pods to crash simultaneously
set -euo pipefail

NAMESPACE="demo-alert-storm"

echo "==> Injecting bad configuration into gateway-config..."

kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: gateway-config-bad
  namespace: demo-alert-storm
data:
  config.yaml: |
    port: 8080
    invalid_directive: true
    routes:
      - path: /
        status: 200
        body: 'healthy'
      - path: /healthz
        status: 200
        body: 'ok'
YAML

echo "==> Patching deployment to reference broken ConfigMap..."
kubectl patch deployment api-gateway -n "${NAMESPACE}" \
  --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"gateway-config-bad"}]'

echo "==> Bad config injected. All 5 pods will crash simultaneously."
