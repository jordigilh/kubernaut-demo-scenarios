#!/usr/bin/env bash
# Red Herring / Multi-Incident Separation Demo -- Automated Runner
# L3 Advanced Diagnostics: Tests LLM ability to separate independent failures
# from a primary cascade when multiple unrelated alerts fire simultaneously.
#
# PRIMARY cascade: postgres crash → api-gateway + worker crash-loop
# RED HERRING: canary-v2 deployment with a nonexistent image (ImagePullBackOff)
#
# The LLM must identify postgres as the root cause for the crash-loops
# and recognize canary-v2 as an unrelated, independent issue.
#
# Prerequisites:
#   - OCP cluster with Kubernaut services
#   - PatchConfiguration ActionType + hotfix-config-v1 workflow
#
# Usage: ./scenarios/red-herring-noise/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-microservices"

APPROVE_MODE="--auto-approve"
SKIP_VALIDATE=""
ALERT_ONLY=""
for _arg in "$@"; do
    case "$_arg" in
        --auto-approve)  APPROVE_MODE="--auto-approve" ;;
        --interactive)   APPROVE_MODE="--interactive" ;;
        --no-validate)   SKIP_VALIDATE=true ;;
        --alert-only)    ALERT_ONLY=true ;;
    esac
done

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
require_demo_ready
# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

echo "============================================="
echo " Red Herring / Multi-Incident Separation (L3)"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

# Step 1: Deploy all workloads (including the canary decoy with bad image)
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for PostgreSQL
echo "==> Step 2: Waiting for postgres to be ready..."
kubectl wait --for=condition=Available deployment/postgres \
  -n "${NAMESPACE}" --timeout=180s
echo "  postgres is running."

# Step 3: Wait for dependent apps
echo "==> Step 3: Waiting for app workloads to be ready..."
kubectl wait --for=condition=Available deployment/api-gateway \
  -n "${NAMESPACE}" --timeout=120s
kubectl wait --for=condition=Available deployment/worker \
  -n "${NAMESPACE}" --timeout=120s
echo "  api-gateway and worker are running."
echo ""
echo "  NOTE: canary-v2 will be deployed after postgres fault (red herring)."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 4: Verify apps can connect to postgres
echo "==> Step 4: Verifying app connectivity to postgres..."
sleep 10
for app in api-gateway worker; do
    logs=$(kubectl logs deploy/${app} -n "${NAMESPACE}" --tail=3 2>/dev/null || echo "")
    if echo "$logs" | grep -q "Health check OK"; then
        echo "  ${app}: connected to postgres successfully"
    else
        echo "  WARNING: ${app} may not be connected to postgres yet"
    fi
done
echo ""

# Step 5: Inject PostgreSQL failure (canary is already broken by design)
echo "==> Step 5: Injecting PostgreSQL failure..."
bash "${SCRIPT_DIR}/inject-faults.sh"
echo ""

echo "==> Step 6: Waiting for alerts."
echo "    PRIMARY: KubePodCrashLooping (api-gateway, worker) → root cause: postgres"
echo "    RED HERRING: ImagePullBackOffPersistent (canary-v2) → independent issue"
echo "    The LLM must not let the canary alert pollute the postgres RCA."

# Validate pipeline
if [ "${ALERT_ONLY}" = "true" ]; then
    echo ""
    echo "==> Waiting for alert (--alert-only mode)..."
    wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 600
    show_alert "KubePodCrashLooping" "${NAMESPACE}"
    echo ""
    echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
    echo "    Exiting without entering validation pipeline."
elif [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}" || _rc=$?
fi

exit "${_rc:-0}"
