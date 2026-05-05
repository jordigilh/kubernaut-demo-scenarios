#!/usr/bin/env bash
# Cross-Namespace Dependency Tracing Demo -- Automated Runner
# L3 Advanced Diagnostics: Tests LLM ability to trace RCA across namespace boundaries.
#
# PostgreSQL lives in demo-xns-infra (shared infrastructure namespace).
# API apps live in demo-xns-app and connect cross-namespace.
# When PG crashes, apps crash-loop with alerts in demo-xns-app.
# The LLM must trace the dependency chain to Deployment/postgres in demo-xns-infra.
#
# Prerequisites:
#   - OCP cluster with Kubernaut services
#   - RollbackDeployment ActionType + rollback-deployment-v1 workflow
#
# Usage: ./scenarios/cross-namespace-dependency/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_NS="demo-xns-infra"
APP_NS="demo-xns-app"
NAMESPACE="${APP_NS}"

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
echo " Cross-Namespace Dependency Tracing Demo (L3)"
echo "============================================="
echo ""

# Clean both namespaces (ensure_clean_slate only handles one)
for ns in "${APP_NS}" "${INFRA_NS}"; do
    ensure_clean_slate "${ns}"
done

# Step 1: Deploy healthy workloads across both namespaces
echo "==> Step 1: Deploying scenario resources (two namespaces)..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for PostgreSQL in infra namespace
echo "==> Step 2: Waiting for postgres in ${INFRA_NS}..."
kubectl wait --for=condition=Available deployment/postgres \
  -n "${INFRA_NS}" --timeout=180s
echo "  postgres is ready in ${INFRA_NS}."

# Step 3: Wait for apps in app namespace
echo "==> Step 3: Waiting for apps in ${APP_NS}..."
kubectl wait --for=condition=Available deployment/api-gateway \
  -n "${APP_NS}" --timeout=120s
kubectl wait --for=condition=Available deployment/payment-processor \
  -n "${APP_NS}" --timeout=120s
echo "  All app deployments healthy in ${APP_NS}."
kubectl get pods -n "${INFRA_NS}"
kubectl get pods -n "${APP_NS}"
echo ""

# Step 4: Verify apps can connect to cross-namespace postgres
echo "==> Step 4: Verifying cross-namespace connectivity..."
sleep 10
for app in api-gateway payment-processor; do
    logs=$(kubectl logs deploy/${app} -n "${APP_NS}" --tail=3 2>/dev/null || echo "")
    if echo "$logs" | grep -q "Health check OK"; then
        echo "  ${app}: connected to postgres.${INFRA_NS}.svc successfully"
    else
        echo "  WARNING: ${app} may not be connected to postgres yet"
    fi
done
echo ""

# Step 5: Inject PostgreSQL failure in infra namespace
echo "==> Step 5: Injecting PostgreSQL failure in ${INFRA_NS}..."
bash "${SCRIPT_DIR}/inject-failure.sh"
echo ""

echo "==> Step 6: Waiting for cascading crash-loops in ${APP_NS}."
echo "    Both api-gateway and payment-processor will lose postgres"
echo "    connectivity and start crash-looping."
echo "    The LLM must trace across namespace boundaries to identify"
echo "    Deployment/postgres in ${INFRA_NS} as the root cause."

# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}" || _rc=$?
fi

exit "${_rc:-0}"
