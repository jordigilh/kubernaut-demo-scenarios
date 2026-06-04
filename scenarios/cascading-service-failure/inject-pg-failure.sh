#!/usr/bin/env bash
# Inject PostgreSQL failure via ConfigMap patch.
# Both order-processor and inventory-sync lose their database dependency and crash.
#
# Fault mechanism: patches postgres-config ConfigMap to add invalid_directive,
# then restarts the Deployment. The entrypoint wrapper detects invalid_directive
# and exits 1 → postgres crashes → dependent apps lose connectivity and crash.
# This aligns with hotfix-config-v1's PatchConfiguration remediation strategy.
set -euo pipefail

NAMESPACE="demo-order-fulfillment"

echo "==> Injecting PostgreSQL failure in ${NAMESPACE} (ConfigMap fault)..."

echo "    Patching postgres-config ConfigMap with invalid_directive..."
kubectl patch configmap postgres-config -n "${NAMESPACE}" --type=merge \
  -p '{"data":{"config.yaml":"startup: enabled\ninvalid_directive: true\ndatabase: demo\nport: 5432\nmax_connections: 100\n"}}'

echo "    Restarting postgres Deployment to pick up bad config..."
kubectl rollout restart deployment/postgres -n "${NAMESPACE}"

echo "    Waiting for postgres to start crash-looping..."
sleep 15
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "==> PostgreSQL failure injected. Dependent apps will crash within ~30s."
