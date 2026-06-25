#!/usr/bin/env bash
# Pending Pods Taint Removal Demo -- Automated Runner
# Scenario #122: Node taint blocks scheduling -> remove taint
#
# Prerequisites:
#   - Kind cluster with worker node (kubernaut.ai/managed=true)
#   - Prometheus with kube-state-metrics
#
# Usage: ./scenarios/pending-taint/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-scheduler"

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
echo " Pending Pods - Taint Removal Demo (#122)"
echo "============================================="
echo ""

_rc=0
if [ "${ALERT_ONLY}" != "true" ]; then
    trap 'echo "==> Restoring EM configuration..."; restore_em || true; exit "${_rc}"' EXIT
    echo "==> Configuring EM for fast EA convergence..."
    configure_em "30s" "120s"
    echo ""
fi

ensure_clean_slate "${NAMESPACE}"

# Step 1: Apply taint to worker node FIRST (before deploying pods)
echo "==> Step 1: Tainting worker node with NoSchedule..."
bash "${SCRIPT_DIR}/inject-taint.sh"
echo ""

# Step 2: Deploy scenario resources (pods will be Pending)
echo "==> Step 2: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 3: Verify pods are Pending
echo "==> Step 3: Verifying pods are stuck in Pending..."
sleep 5
kubectl get pods -n "${NAMESPACE}"
echo "  Pods should show Pending (taint blocks scheduling on worker node)."
echo ""

# Step 4: Wait for alert
echo "==> Step 4: Waiting for Pending alert to fire (~3 min)..."
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""

# Step 5: Validate pipeline
if [ "${ALERT_ONLY}" = "true" ]; then
    echo ""
    echo "==> Waiting for alert (--alert-only mode)..."
    wait_for_alert "KubePodNotScheduled" "${NAMESPACE}" 480
    show_alert "KubePodNotScheduled" "${NAMESPACE}"
    echo ""
    echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
    echo "    Exiting without entering validation pipeline."
elif [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
