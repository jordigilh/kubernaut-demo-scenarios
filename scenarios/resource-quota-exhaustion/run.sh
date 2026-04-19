#!/usr/bin/env bash
# Resource Quota Exhaustion Demo -- Automated Runner
# Scenario #171: ResourceQuota prevents pod creation -> LLM escalates to human review
#
# The deployment is created with replicas=3 from the start, but the namespace
# ResourceQuota only allows 512Mi total (2 pods × 256Mi). The 3rd replica is
# permanently blocked by FailedCreate admission errors. Because the deployment
# was NEVER healthy at its desired replica count and revision 1 IS the
# 3-replica version, there is no previous state to rollback to. The LLM must
# recognise this as a capacity/policy constraint and escalate to
# ManualReviewRequired.
#
# Prerequisites:
#   - Kind cluster (kubernaut-demo) with platform installed
#   - Prometheus with kube-state-metrics
#
# Usage: ./scenarios/resource-quota-exhaustion/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-quota"

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
echo " Resource Quota Exhaustion Demo (#171)"
echo " Policy Constraint -> ManualReviewRequired"
echo "============================================="
echo ""

# Enable KA Prometheus toolset for this scenario (kubernaut#473, #108).
echo "==> Enabling Kubernaut Agent Prometheus toolset for this scenario..."
enable_prometheus_toolset
force_production_approval
echo ""

ensure_clean_slate "${NAMESPACE}"

# Step 1: Deploy scenario resources (3 replicas requested, only 2 fit in quota)
echo "==> Step 1: Deploying scenario resources (3 replicas × 256Mi vs 512Mi quota)..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

echo "==> Step 2: Waiting for partial deployment (2/3 pods will come up)..."
sleep 15
echo ""
echo "  Pod status:"
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "  ReplicaSet status (desired > ready = quota exhausted):"
kubectl get rs -n "${NAMESPACE}"
echo ""
echo "  ResourceQuota usage:"
kubectl describe quota namespace-quota -n "${NAMESPACE}"
echo ""
echo "  FailedCreate events:"
kubectl get events -n "${NAMESPACE}" --field-selector reason=FailedCreate --sort-by='.lastTimestamp' 2>/dev/null | tail -5
echo ""

echo "==> Deployment created with quota exceeded from the start."
echo "    No previous revision exists -- rollback is not possible."
echo "    Waiting for KubeResourceQuotaExhausted alert (~30s-2 min)."

# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
