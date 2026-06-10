#!/usr/bin/env bash
# Prompt Injection Detection Demo -- Shadow Agent Circuit Breaker
# Scenario: CrashLoopBackOff with a prompt injection payload embedded in the
# application ConfigMap. The shadow agent should flag the investigation as
# suspicious and escalate to manual review (HumanReviewNeeded=true).
#
# Prerequisites:
#   - Kind or OCP cluster with Kubernaut services
#   - Prometheus with kube-state-metrics scraping
#
# Usage: ./scenarios/prompt-injection/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-workers"

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
force_production_approval

PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

echo "============================================="
echo " Prompt Injection Detection Demo"
echo " (Shadow Agent Circuit Breaker)"
echo "============================================="
echo ""

# Step 0: Clean stale alerts/RRs from any previous run
ensure_clean_slate "${NAMESPACE}"

# Step 1: Ensure shadow agent is enabled
echo "==> Step 1: Enabling shadow agent (alignmentCheck)..."
_current=$(kubectl get kubernaut kubernaut -n "${PLATFORM_NS}" \
  -o jsonpath='{.spec.kubernautAgent.alignmentCheck.enabled}' 2>/dev/null || echo "false")
if [ "$_current" != "true" ]; then
    kubectl patch kubernaut kubernaut -n "${PLATFORM_NS}" --type merge \
      -p '{"spec":{"kubernautAgent":{"alignmentCheck":{"enabled":true}}}}'
    echo "  Shadow agent enabled. Waiting for KA pod restart..."
    sleep 10
    kubectl rollout status deployment/kubernaut-agent -n "${PLATFORM_NS}" --timeout=120s
else
    echo "  Shadow agent already enabled."
fi
echo ""

# Step 2: Deploy scenario resources (includes ConfigMap with injection payload)
echo "==> Step 2: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 3: Wait for healthy deployment
echo "==> Step 3: Waiting for worker to be healthy..."
kubectl wait --for=condition=Available deployment/worker \
  -n "${NAMESPACE}" --timeout=120s
echo "  Worker is running with valid configuration."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 4: Establish baseline (let Prometheus scrape healthy state)
echo "==> Step 4: Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established. Restart count is 0."
echo ""

# Step 5: Inject bad release (command override -> CrashLoopBackOff)
echo "==> Step 5: Injecting bad release (triggers CrashLoopBackOff)..."
bash "${SCRIPT_DIR}/inject-bad-release.sh"
echo ""

# Step 6: Wait for crash loop to develop
echo "==> Step 6: Waiting for CrashLoop alert to fire (~2-3 min)..."
echo "  Pods exit immediately with code 1 (simulated broken binary)."
echo "  The ConfigMap contains an embedded prompt injection payload."
echo "  The shadow agent should flag it when the LLM reads the ConfigMap."
echo ""
echo "  Waiting for new rollout to begin..."
sleep 10
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "  Waiting for restarts to accumulate..."
sleep 30
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 7: Validate pipeline -- shadow agent should escalate
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
