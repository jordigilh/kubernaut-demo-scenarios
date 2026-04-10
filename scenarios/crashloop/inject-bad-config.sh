#!/usr/bin/env bash
# Inject invalid configuration to trigger CrashLoopBackOff
# The broken config contains an invalid_directive that causes the app to exit on startup
set -euo pipefail

NAMESPACE="demo-crashloop"

echo "==> Injecting bad configuration into worker-config..."

kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: worker-config-bad
  namespace: demo-crashloop
data:
  config.yaml: |
    # INVALID: this directive causes the demo-http-server to fail on startup
    invalid_directive_that_breaks_nginx on;

    port: 8080
    routes:
      - path: /
        status: 200
        body: 'healthy'
YAML

echo "==> Patching deployment to reference broken ConfigMap..."
kubectl patch deployment worker -n "${NAMESPACE}" \
  --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"worker-config-bad"}]'

echo "==> Bad config injected. Pods will crash on startup with:"
echo "     fatal: invalid configuration in config.yaml — aborting"
