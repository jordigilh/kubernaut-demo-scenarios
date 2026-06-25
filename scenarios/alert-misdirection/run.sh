#!/usr/bin/env bash
# Alert Misdirection Demo -- Automated Runner
# Scenario: Bad release -> CrashLoopBackOff, but alert description falsely
# claims OOM. Tests whether the LLM investigates cluster evidence rather than
# blindly trusting the alert metadata.
#
# The actual root cause is identical to crashloop (#120): a command override
# that exits immediately with code 1. The LLM must discover this from pod
# logs/events and select the rollback workflow, ignoring the OOM narrative.
#
# Prerequisites:
#   - Kind or OCP cluster with Kubernaut services
#   - Prometheus with kube-state-metrics scraping
#   - crashloop-rollback-v1 workflow deployed
#
# Usage: ./scenarios/alert-misdirection/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-backend"

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

_rc=0
if [ "${ALERT_ONLY}" != "true" ]; then
    trap 'echo "==> Restoring EM configuration..."; restore_em || true; exit "${_rc}"' EXIT
    echo "==> Configuring EM for fast EA convergence..."
    configure_em "30s" "120s"
    echo ""
fi

echo "============================================="
echo " Alert Misdirection Demo"
echo "============================================="
echo " Tests LLM reasoning resilience against"
echo " misleading alert descriptions."
echo ""

ensure_clean_slate "${NAMESPACE}"

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for healthy deployment
echo "==> Step 2: Waiting for worker to be healthy..."
kubectl wait --for=condition=Available deployment/worker \
  -n "${NAMESPACE}" --timeout=120s
echo "  Worker is running with valid configuration."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 3: Establish baseline (let Prometheus scrape healthy state)
echo "==> Step 3: Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established. Restart count is 0."
echo ""

# Step 4: Inject bad release (command override — NOT an OOM issue)
echo "==> Step 4: Injecting bad release (triggers CrashLoopBackOff)..."
echo "    NOTE: The alert description will claim this is an OOM issue."
echo "          The actual cause is a broken command override (exit 1)."
bash "${SCRIPT_DIR}/inject-bad-release.sh"
echo ""

# Step 5: Wait for pods to start crashing
echo "==> Step 5: Waiting for CrashLoop alert to fire (~2-3 min)..."
echo "  Pods exit immediately with code 1 (simulated broken binary)."
echo "  No OOM events will be present — the alert description is wrong."
echo ""
echo "  Waiting for new rollout to begin..."
sleep 10
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "  Waiting for restarts to accumulate..."
sleep 30
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 6: Validate pipeline
if [ "${ALERT_ONLY}" = "true" ]; then
    echo ""
    echo "==> Waiting for alert (--alert-only mode)..."
    wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 480
    show_alert "KubePodCrashLooping" "${NAMESPACE}"
    echo ""
    echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
    echo "    Exiting without entering validation pipeline."
elif [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}" || _rc=$?
fi
