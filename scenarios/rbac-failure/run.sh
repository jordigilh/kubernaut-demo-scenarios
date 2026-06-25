#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-monitoring"

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

enable_prometheus_toolset
force_production_approval

echo "============================================="
echo " RBAC Failure Remediation Demo"
echo " RoleBinding deleted -> 403 Forbidden"
echo " -> RestoreRoleBinding"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

echo "==> Step 2: Waiting for deployment to be Available..."
kubectl wait --for=condition=Available deployment/metrics-collector \
  -n "${NAMESPACE}" --timeout=120s
kubectl get pods -n "${NAMESPACE}"
echo ""

echo "==> Step 3: Establishing healthy baseline (20s)..."
sleep 20
echo ""

echo "==> Step 4: Injecting RBAC failure (delete RoleBinding)..."
bash "${SCRIPT_DIR}/inject-rbac-revoke.sh"
echo ""

kubectl get pods -n "${NAMESPACE}"
echo ""
POD=$(kubectl get pods -n "${NAMESPACE}" -l app=metrics-collector \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "${POD}" ]; then
    kubectl describe pod "${POD}" -n "${NAMESPACE}" || true
fi
echo ""

if [ "${ALERT_ONLY}" = "true" ]; then
    echo ""
    echo "==> Waiting for alert (--alert-only mode)..."
    wait_for_alert "RBACPolicyDenied" "${NAMESPACE}" 480
    show_alert "RBACPolicyDenied" "${NAMESPACE}"
    echo ""
    echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
    echo "    Exiting without entering validation pipeline."
elif [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
