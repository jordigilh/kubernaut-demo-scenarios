#!/usr/bin/env bash
# Orphaned PVC Demo — Warning-Aware Rego Policy (#60, #122)
#
# Runs in a STAGING namespace with a custom approval policy that catches LLM
# warnings. The cleanup-pvc-v1 workflow IS in the catalog — this tests
# genuine LLM judgment when a matching workflow exists but the situation may
# not warrant intervention.
#
# Two valid paths:
#   A) LLM says actionable=false         → NoActionRequired (auto-completes)
#   B) LLM selects CleanupPVC + warns    → has_warnings Rego → AwaitingApproval
#
# In staging, the DEFAULT policy would auto-approve Path B. The custom
# warning-aware policy catches it and forces human review.
#
# Prerequisites:
#   - Kind or OCP cluster with Kubernaut services
#   - Prometheus with kube-state-metrics
#   - StorageClass "standard" (Kind) or cluster default (OCP)
#
# Usage: ./scenarios/orphaned-pvc-no-action/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-orphaned-pvc"

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
echo " Orphaned PVC Demo (#60, #122)"
echo " Staging + Warning-Aware Rego"
echo "============================================="
echo ""

# Step 1: Patch the approval Rego with the has_warnings rule.
# Back up the current policy so cleanup.sh can restore it.
echo "==> Step 1: Patching approval policy with warning-aware Rego..."
kubectl get configmap aianalysis-policies -n "${PLATFORM_NS}" \
  -o jsonpath='{.data.approval\.rego}' > "${SCRIPT_DIR}/.approval-rego-backup" 2>/dev/null || true

kubectl patch configmap aianalysis-policies -n "${PLATFORM_NS}" --type=merge \
  -p "{\"data\":{\"approval.rego\":$(cat "${SCRIPT_DIR}/rego/approval-warnings.rego" | jq -Rs .)}}"

echo "  Restarting AIAnalysis controller to pick up policy change..."
kubectl rollout restart deployment/aianalysis-controller -n "${PLATFORM_NS}"
kubectl rollout status deployment/aianalysis-controller -n "${PLATFORM_NS}" --timeout=60s
echo ""

# Step 2: Deploy scenario resources
echo "==> Step 2: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"
ensure_ocp_namespace_monitoring "${NAMESPACE}"

# Step 3: Wait for healthy deployment
echo "==> Step 3: Waiting for data-processor to be ready..."
kubectl wait --for=condition=Available deployment/data-processor \
  -n "${NAMESPACE}" --timeout=120s
echo "  data-processor is running."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 4: Inject orphaned PVCs
echo "==> Step 4: Creating orphaned PVCs from simulated batch jobs..."
bash "${SCRIPT_DIR}/inject-orphan-pvcs.sh"
echo ""

echo "==> Step 5: Fault injected. Waiting for KubePersistentVolumeClaimOrphaned alert (~3 min)."
echo ""
echo "  Expected outcomes (both are valid — LLM is non-deterministic):"
echo "    Path A: LLM says not actionable   → NoActionRequired (auto-complete)"
echo "    Path B: LLM selects CleanupPVC    → llm_warns_no_remediation Rego → AwaitingApproval"
echo "            (approval reason: 'LLM warning: no remediation warranted')"
echo ""

# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
