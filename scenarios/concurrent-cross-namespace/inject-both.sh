#!/usr/bin/env bash
# Inject bad config into both team-alpha and team-beta namespaces.
#
# Mutates the existing worker-config ConfigMap in-place (adds invalid_directive)
# then triggers a rollout restart so new pods pick up the bad config and crash.
# The Deployment spec (volume reference) stays unchanged -- the root cause is
# purely ConfigMap content, which aligns with hotfix-config-v1's PatchConfiguration
# remediation strategy.
#
# Because the Deployment uses a subPath volume mount, the old ReplicaSet's pods
# retain the cached good config. This means rollback also stabilises the
# Deployment (for crashloop-rollback-risk-v1 / Team Beta).
set -euo pipefail

for NS in demo-team-alpha demo-team-beta; do
  echo "==> Injecting bad config into ${NS}..."

  kubectl patch configmap worker-config -n "${NS}" --type=merge \
    -p '{"data":{"config.yaml":"port: 8080\ninvalid_directive: true\nroutes:\n  - path: /\n    status: 200\n    body: \"healthy\"\n  - path: /healthz\n    status: 200\n    body: \"ok\"\n"}}'

  kubectl rollout restart deployment/worker -n "${NS}"
done

echo "==> Bad config injected in both namespaces. New pods will crash."
