#!/usr/bin/env bash
# Inject faults in sequence to ensure correct signal ordering:
# 1. PRIMARY: Break PostgreSQL via ConfigMap → causes api-gateway and worker to crash-loop
# 2. RED HERRING: Deploy canary-v2 with a nonexistent image tag (after crash-loop starts)
#
# The canary-v2 is deployed AFTER the postgres fault so that KubePodCrashLooping
# fires before ImagePullBackOffPersistent, ensuring the platform processes the
# primary signal first.
#
# Fault mechanism: patches postgres-config ConfigMap to add invalid_directive,
# then restarts the Deployment. The entrypoint wrapper detects invalid_directive
# and exits 1 → postgres crashes → dependent apps lose connectivity and crash.
# This aligns with hotfix-config-v1's PatchConfiguration remediation strategy.
set -euo pipefail

NAMESPACE="demo-red-herring"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Injecting PostgreSQL failure in ${NAMESPACE} (ConfigMap fault)..."

echo "    Patching postgres-config ConfigMap with invalid_directive..."
kubectl patch configmap postgres-config -n "${NAMESPACE}" --type=merge \
  -p '{"data":{"config.yaml":"startup: enabled\ninvalid_directive: true\ndatabase: demo\nport: 5432\nmax_connections: 100\n"}}'

echo "    Restarting postgres Deployment to pick up bad config..."
kubectl rollout restart deployment/postgres -n "${NAMESPACE}"

echo "    Waiting for crash-loop to begin before deploying red herring..."
sleep 45

echo "    Deploying canary-v2 decoy (red herring — nonexistent image)..."
kubectl apply -f "${SCRIPT_DIR}/manifests/canary-decoy.yaml"

kubectl get pods -n "${NAMESPACE}"
echo ""
echo "==> Faults injected."
echo "    PRIMARY: postgres crash (invalid_directive in ConfigMap) → api-gateway + worker crash-loop"
echo "    RED HERRING: canary-v2 stuck in ImagePullBackOff (unrelated)"
echo "    The LLM must separate these independent incidents."
