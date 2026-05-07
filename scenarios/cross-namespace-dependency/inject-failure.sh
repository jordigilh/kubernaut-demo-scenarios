#!/usr/bin/env bash
# Inject PostgreSQL failure in the shared infrastructure namespace via ConfigMap.
# Apps in demo-xns-app lose their cross-namespace dependency and crash.
#
# Fault mechanism: patches postgres-config ConfigMap to add invalid_directive,
# then restarts the Deployment. The entrypoint wrapper detects invalid_directive
# and exits 1 → postgres crashes → dependent apps lose connectivity and crash.
# This aligns with hotfix-config-v1's PatchConfiguration remediation strategy.
set -euo pipefail

INFRA_NS="demo-xns-infra"

echo "==> Injecting PostgreSQL failure in ${INFRA_NS} (ConfigMap fault)..."

echo "    Patching postgres-config ConfigMap with invalid_directive..."
kubectl patch configmap postgres-config -n "${INFRA_NS}" --type=merge \
  -p '{"data":{"config.yaml":"startup: enabled\ninvalid_directive: true\ndatabase: demo\nport: 5432\nmax_connections: 100\n"}}'

echo "    Restarting postgres Deployment to pick up bad config..."
kubectl rollout restart deployment/postgres -n "${INFRA_NS}"

echo "    Waiting for postgres to start crash-looping..."
sleep 15
kubectl get pods -n "${INFRA_NS}"
echo ""
echo "==> PostgreSQL failure injected in ${INFRA_NS}."
echo "    Apps in demo-xns-app will lose cross-namespace connectivity within ~30s."
