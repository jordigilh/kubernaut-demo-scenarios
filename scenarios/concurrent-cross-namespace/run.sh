#!/usr/bin/env bash
# Concurrent Cross-Namespace Demo -- Automated Runner
# Scenario #172: Two teams, same issue, different risk tolerance -> different workflows
#
# Team Alpha (high risk tolerance) -> restart-pods-v1 (simpler, faster)
# Team Beta  (low risk tolerance)  -> crashloop-rollback-v1 (safer, more thorough)
#
# This scenario also fixes the SP Rego custom labels policy bug (package name mismatch).
#
# Prerequisites:
#   - Kind cluster with Kubernaut platform deployed
#   - Prometheus with kube-state-metrics
#
# Usage: ./scenarios/concurrent-cross-namespace/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

echo "============================================="
echo " Concurrent Cross-Namespace Demo (#172)"
echo " Same Issue, Different Risk -> Different Workflows"
echo "============================================="
echo ""

# Step 0: Fix the SP Rego custom labels policy
echo "==> Step 0: Patching SP custom labels Rego policy (fix package name)..."
kubectl create configmap signalprocessing-customlabels-policy \
  --from-file=customlabels.rego="${SCRIPT_DIR}/rego/risk-tolerance.rego" \
  -n kubernaut-system \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  Restarting SignalProcessing controller to pick up policy change..."
kubectl rollout restart deployment/signalprocessing-controller -n kubernaut-system
kubectl rollout status deployment/signalprocessing-controller -n kubernaut-system --timeout=60s
echo ""

# Step 0b: Register risk-tolerance-aware workflows as RemediationWorkflow CRDs
echo "==> Step 0b: Applying RemediationWorkflow CRDs..."
kubectl apply -f "${SCRIPT_DIR}/workflow/" -n kubernaut-system
echo ""

# Step 1: Deploy both namespaces and workloads
echo "==> Step 1: Deploying team-alpha and team-beta workloads..."
echo "  Deploying both teams..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"
echo ""

# Step 2: Wait for healthy deployments
echo "==> Step 2: Waiting for both deployments to be healthy..."
kubectl wait --for=condition=Available deployment/worker -n demo-team-alpha --timeout=120s
kubectl wait --for=condition=Available deployment/worker -n demo-team-beta --timeout=120s
echo "  Both teams running."
echo ""

# Step 3: Establish baseline
echo "==> Step 3: Establishing healthy baseline (20s)..."
sleep 20
echo ""

# Step 4: Inject bad config into BOTH namespaces
echo "==> Step 4: Injecting bad config into both namespaces simultaneously..."
bash "${SCRIPT_DIR}/inject-both.sh"
echo ""

# Step 5: Expected behavior
echo "==> Step 5: Both pipelines running in parallel."
echo ""
echo "  Expected:"
echo "    Team Alpha (high risk tolerance):"
echo "      -> SP enriches with customLabels: {risk_tolerance: [high]}"
echo "      -> DataStorage boosts restart-pods-v1 (customLabels match)"
echo "      -> LLM selects restart-pods-v1 (simpler, aligns with risk tolerance)"
echo ""
echo "    Team Beta (low risk tolerance):"
echo "      -> SP enriches with customLabels: {risk_tolerance: [low]}"
echo "      -> DataStorage boosts crashloop-rollback-v1 (customLabels match)"
echo "      -> LLM selects crashloop-rollback-v1 (safer, more thorough)"
echo ""
# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
