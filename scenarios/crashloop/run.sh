#!/usr/bin/env bash
# CrashLoopBackOff Demo -- Automated Runner
# Scenario #120: Bad config deploy -> CrashLoopBackOff -> rollback
#
# Prerequisites:
#   - Kind or OCP cluster with Kubernaut services
#   - Prometheus with kube-state-metrics scraping
#
# Usage: ./scenarios/crashloop/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-crashloop"

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

enable_prometheus_toolset

echo "============================================="
echo " CrashLoopBackOff Remediation Demo (#120)"
echo "============================================="
echo ""

# Step 0: Clean up stale alerts/RRs from any previous run (#193)
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

# Step 4: Inject bad configuration
echo "==> Step 4: Injecting invalid nginx config (triggers CrashLoopBackOff)..."
bash "${SCRIPT_DIR}/inject-bad-config.sh"
echo ""

# Step 5: Wait for pods to start crashing and alert to fire
echo "==> Step 5: Waiting for CrashLoop alert to fire (~2-3 min)..."
echo "  Pods will fail to start with 'unknown directive' error."
echo ""
echo "  Waiting for new rollout to begin..."
sleep 10
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "  Waiting for restarts to accumulate..."
sleep 30
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "  The KubePodCrashLooping alert fires after >3 restarts in 10 min."
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""

# Step 6: Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
