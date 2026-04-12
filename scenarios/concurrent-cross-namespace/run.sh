#!/usr/bin/env bash
# Concurrent Cross-Namespace Demo -- Automated Runner
# Scenario #172: Two teams, same issue, different risk tolerance -> different workflows
#
# Team Alpha (high risk tolerance) -> hotfix-config-v1 (patches ConfigMap in-place, faster)
# Team Beta  (low risk tolerance)  -> crashloop-rollback-risk-v1 (full rollback, safer)
#
# The risk_tolerance rules are injected into policy.rego at runtime (#216).
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
# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"
require_demo_ready

enable_prometheus_toolset

echo "============================================="
echo " Concurrent Cross-Namespace Demo (#172)"
echo " Same Issue, Different Risk -> Different Workflows"
echo "============================================="
echo ""

# Step 0a: Clean up stale alerts/RRs from any previous run (#193)
ensure_clean_slate "demo-team-alpha"
ensure_clean_slate "demo-team-beta"

# Step 0b: Inject risk-tolerance rules into the SP policy ConfigMap.
# The SP controller only loads the policy.rego key, so we append the
# risk_tolerance extraction rules directly into it (not a separate key).
# We save the original content as an annotation so cleanup.sh can restore it.
#
# Guard: if a previous run crashed before cleanup, the annotation already holds
# the real original. Restore it first to avoid double-appending risk-tolerance rules.
echo "==> Step 0b: Injecting risk-tolerance rules into SP policy.rego..."

EXISTING_B64=$(kubectl get configmap signalprocessing-policy -n "${PLATFORM_NS}" \
  -o jsonpath='{.metadata.annotations.kubernaut\.ai/original-policy-rego}' 2>/dev/null || echo "")
if [ -n "${EXISTING_B64}" ]; then
    echo "  Restoring original policy from previous run's annotation..."
    ORIGINAL_POLICY=$(echo "${EXISTING_B64}" | base64 -d)
    kubectl patch configmap signalprocessing-policy -n "${PLATFORM_NS}" --type=merge \
      -p "{\"data\":{\"policy.rego\":$(echo "${ORIGINAL_POLICY}" | jq -Rs .)}}"
else
    ORIGINAL_POLICY=$(kubectl get configmap signalprocessing-policy -n "${PLATFORM_NS}" \
      -o jsonpath='{.data.policy\.rego}')
fi

kubectl annotate configmap signalprocessing-policy -n "${PLATFORM_NS}" \
  "kubernaut.ai/original-policy-rego=$(echo "${ORIGINAL_POLICY}" | base64)" --overwrite

RISK_RULES=$(grep -v -E '^(package |import )' "${SCRIPT_DIR}/rego/risk-tolerance.rego")

MERGED_POLICY="${ORIGINAL_POLICY}

${RISK_RULES}"

kubectl patch configmap signalprocessing-policy -n "${PLATFORM_NS}" --type=merge \
  -p "{\"data\":{\"policy.rego\":$(echo "${MERGED_POLICY}" | jq -Rs .)}}"

echo "  Restarting SignalProcessing controller to pick up policy change..."
kubectl rollout restart deployment/signalprocessing-controller -n "${PLATFORM_NS}"
kubectl rollout status deployment/signalprocessing-controller -n "${PLATFORM_NS}" --timeout=60s
echo ""

# Step 0c: Remove stale restart-pods-v1 (replaced by hotfix-config-v1 in Option D redesign)
echo "==> Step 0c: Removing stale restart-pods-v1 workflow (if present)..."
kubectl delete remediationworkflow restart-pods-v1 -n "${PLATFORM_NS}" --ignore-not-found 2>/dev/null || true
kubectl delete clusterrolebinding restart-pods-v1-runner --ignore-not-found 2>/dev/null || true
kubectl delete clusterrole restart-pods-v1-runner --ignore-not-found 2>/dev/null || true
kubectl delete serviceaccount restart-pods-v1-runner -n "${WE_NAMESPACE:-kubernaut-workflows}" --ignore-not-found 2>/dev/null || true
echo ""

# Step 0d: Register risk-tolerance-aware workflows as RemediationWorkflow CRDs
echo "==> Step 0d: Applying RemediationWorkflow CRDs..."
for yaml_file in "${REPO_ROOT}/deploy/remediation-workflows/concurrent-cross-namespace/"*.yaml; do
    _apply_workflow_yaml "$yaml_file" "${PLATFORM_NS}"
done
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
echo "    Team Alpha (staging, high risk tolerance):"
echo "      -> Auto-approved (environment=staging)"
echo "      -> SP enriches with customLabels: {risk_tolerance: [high]}"
echo "      -> DataStorage boosts hotfix-config-v1 (customLabels match)"
echo "      -> LLM selects hotfix-config-v1 (patches ConfigMap in-place, faster)"
echo ""
echo "    Team Beta (production, low risk tolerance):"
echo "      -> Requires manual approval (environment=production)"
echo "      -> SP enriches with customLabels: {risk_tolerance: [low]}"
echo "      -> DataStorage boosts crashloop-rollback-risk-v1 (customLabels match)"
echo "      -> LLM selects crashloop-rollback-risk-v1 (full rollback, safer)"
echo ""
# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
