#!/usr/bin/env bash
# Inject bad config into both team-alpha and team-beta namespaces
set -euo pipefail

for NS in demo-team-alpha demo-team-beta; do
  echo "==> Injecting bad config into ${NS}..."
  kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: worker-config-bad
  namespace: ${NS}
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

  kubectl patch deployment worker -n "${NS}" \
    --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"worker-config-bad"}]'
done

echo "==> Bad config injected in both namespaces. All pods will crash."
