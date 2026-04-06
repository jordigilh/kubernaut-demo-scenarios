#!/usr/bin/env bash
# Inject bad config for SLO Burn Demo (#128)
#
# Creates a separate "api-config-bad" ConfigMap that returns 500 on /api/,
# then patches the Deployment to reference it. This ensures `kubectl rollout undo`
# reverts the volume reference back to the healthy "api-config" ConfigMap.
#
# Health checks (/healthz) still pass -- realistic production failure mode.
set -euo pipefail

NAMESPACE="demo-slo"

echo "==> Creating bad ConfigMap (500 errors on /api/)..."
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-config-bad
  namespace: demo-slo
  labels:
    app: api-gateway
data:
  config.yaml: |
    port: 8080
    routes:
      - path: /api/status
        status: 500
        body: 'internal server error'
      - path: /api/
        status: 500
        body: 'internal server error'
      - path: /healthz
        status: 200
        body: 'ok'
YAML

echo "==> Patching deployment to reference bad ConfigMap..."
kubectl patch deployment api-gateway -n "${NAMESPACE}" --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"api-config-bad"}
]'

echo "==> Waiting for rollout to complete..."
kubectl rollout status "deployment/api-gateway" -n "${NAMESPACE}" --timeout=60s

echo "==> Bad deploy complete."
echo "    /healthz returns 200 (readiness passes)"
echo "    /api/*   returns 500 (service is broken)"
echo "    Deployment now references api-config-bad (rollout undo reverts to api-config)"
echo "    SLO burn rate alert should fire within ~5 minutes."
