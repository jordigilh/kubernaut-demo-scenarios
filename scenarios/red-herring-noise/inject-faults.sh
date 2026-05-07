#!/usr/bin/env bash
# Inject two simultaneous faults:
# 1. PRIMARY: Break PostgreSQL via ConfigMap → causes api-gateway and worker to crash-loop
# 2. RED HERRING: canary-v2 already deployed with a nonexistent image tag
#
# The canary-v2 ImagePullBackOff is unrelated to the postgres cascade.
# The LLM must separate these independent incidents.
#
# Fault mechanism: patches postgres-config ConfigMap to add invalid_directive,
# then restarts the Deployment. The entrypoint wrapper detects invalid_directive
# and exits 1 → postgres crashes → dependent apps lose connectivity and crash.
# This aligns with hotfix-config-v1's PatchConfiguration remediation strategy.
set -euo pipefail

NAMESPACE="demo-red-herring"

echo "==> Injecting PostgreSQL failure in ${NAMESPACE} (ConfigMap fault)..."

echo "    Patching postgres-config ConfigMap with invalid_directive..."
kubectl patch configmap postgres-config -n "${NAMESPACE}" --type=merge \
  -p '{"data":{"config.yaml":"startup: enabled\ninvalid_directive: true\ndatabase: demo\nport: 5432\nmax_connections: 100\n"}}'

echo "    Restarting postgres Deployment to pick up bad config..."
kubectl rollout restart deployment/postgres -n "${NAMESPACE}"

echo "    Waiting for faults to propagate..."
sleep 15
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "==> Faults injected."
echo "    PRIMARY: postgres crash (invalid_directive in ConfigMap) → api-gateway + worker crash-loop"
echo "    RED HERRING: canary-v2 stuck in ImagePullBackOff (unrelated)"
echo "    The LLM must separate these independent incidents."
