#!/usr/bin/env bash
# Severity Misdirection Demo -- Automated Runner
# L3 Advanced Diagnostics: Tests LLM ability to prioritize temporal causation
# over alert severity when a high-severity alert is a symptom of a low-severity
# root cause.
#
# PostgreSQL is OOM-killed (warning) → api-gateway crash-loops (critical).
# The LLM sees both alerts but must identify the warning-level OOM as the
# root cause, not chase the louder critical crash-loop.
#
# Prerequisites:
#   - OCP cluster with Kubernaut services
#   - RollbackDeployment or IncreaseMemoryLimits workflow
#
# Usage: ./scenarios/severity-misdirection/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-services"

APPROVE_MODE="--auto-approve"
SKIP_VALIDATE=""
for _arg in "$@"; do
    case "$_arg" in
        --auto-approve)  APPROVE_MODE="--auto-approve" ;;
        --interactive)   APPROVE_MODE="--interactive" ;;
        --no-validate)   SKIP_VALIDATE=true ;;
    esac
done

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
require_demo_ready
# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

echo "============================================="
echo " Severity Misdirection Demo (L3)"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

# Step 1: Deploy healthy workloads
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for PostgreSQL to be healthy
echo "==> Step 2: Waiting for postgres to be ready..."
kubectl wait --for=condition=Available deployment/postgres \
  -n "${NAMESPACE}" --timeout=180s
echo "  postgres is running."

# Step 3: Wait for api-gateway
echo "==> Step 3: Waiting for api-gateway to be ready..."
kubectl wait --for=condition=Available deployment/api-gateway \
  -n "${NAMESPACE}" --timeout=120s
echo "  api-gateway is running."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 4: Verify app can connect to postgres
echo "==> Step 4: Verifying api-gateway connectivity..."
sleep 10
logs=$(kubectl logs deploy/api-gateway -n "${NAMESPACE}" --tail=3 2>/dev/null || echo "")
if echo "$logs" | grep -q "Health check OK"; then
    echo "  api-gateway: connected to postgres successfully"
else
    echo "  WARNING: api-gateway may not be connected to postgres yet"
fi
echo ""

# Step 5: Inject OOM on postgres
echo "==> Step 5: Injecting OOM condition on postgres..."
bash "${SCRIPT_DIR}/inject-oom.sh"
echo ""

echo "==> Step 6: Waiting for severity-misdirected alerts."
echo "    1. ContainerOOMKilling (warning) fires first -- postgres OOM"
echo "    2. KubePodCrashLooping (critical) fires second -- api-gateway"
echo "    The LLM must identify the warning OOM as the root cause."

# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}" || _rc=$?
fi

exit "${_rc:-0}"
