#!/usr/bin/env bash
# Cascading Service Failure Demo -- Automated Runner
# L3 Problem Management: Tests RO target-based dedup when two independent
# RRs converge on the same RemediationTarget.
#
# PostgreSQL is the shared dependency for order-processor and inventory-sync.
# When PG crashes, both apps crash-loop, generating two independent RRs.
# The LLM investigates both and identifies Deployment/postgres as the root
# cause for each. The RO's AcquireLock + CheckResourceBusy ensures only
# one WFE runs against postgres; the other RR is Blocked (ResourceBusy).
#
# Prerequisites:
#   - OCP cluster with Kubernaut services
#   - RollbackDeployment ActionType + rollback-deployment-v1 workflow
#
# Usage: ./scenarios/cascading-service-failure/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-cascade"

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
echo " Cascading Service Failure Demo (L3)"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

# Step 1: Deploy healthy workloads
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for everything to be healthy
echo "==> Step 2: Waiting for all deployments to be ready..."
kubectl wait --for=condition=Available deployment/postgres \
  -n "${NAMESPACE}" --timeout=180s
kubectl wait --for=condition=Available deployment/order-processor \
  -n "${NAMESPACE}" --timeout=120s
kubectl wait --for=condition=Available deployment/inventory-sync \
  -n "${NAMESPACE}" --timeout=120s
echo "  All deployments healthy."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 3: Verify apps can connect to postgres
echo "==> Step 3: Verifying app connectivity to postgres..."
sleep 10
for app in order-processor inventory-sync; do
    logs=$(kubectl logs deploy/${app} -n "${NAMESPACE}" --tail=3 2>/dev/null || echo "")
    if echo "$logs" | grep -q "Health check OK"; then
        echo "  ${app}: connected to postgres successfully"
    else
        echo "  WARNING: ${app} may not be connected to postgres yet"
    fi
done
echo ""

# Step 4: Inject PostgreSQL failure
echo "==> Step 4: Injecting PostgreSQL failure..."
bash "${SCRIPT_DIR}/inject-pg-failure.sh"
echo ""

echo "==> Step 5: Waiting for cascading crash-loops."
echo "    Both order-processor and inventory-sync will lose postgres"
echo "    connectivity and start crash-looping."
echo "    Two separate KubePodCrashLooping alerts will fire."
echo "    The LLM should identify Deployment/postgres as the root cause"
echo "    for both, triggering ResourceBusy dedup."

# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}" || _rc=$?
fi

exit "${_rc:-0}"
