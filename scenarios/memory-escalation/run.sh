#!/usr/bin/env bash
# Memory Escalation Demo -- Automated Runner
# Scenario #168: OOMKill -> increase memory limits -> OOMKill again -> escalation
#
# Demonstrates how the platform handles diminishing remediation effectiveness:
# The ml-worker consumes unbounded memory (simulating a leak). Increasing limits
# only delays the OOMKill. After consecutive failures (same workflow, same issue),
# the RO escalates to human review via CheckConsecutiveFailures (for Failed RRs)
# or CheckIneffectiveRemediationChain (Issue #214: for Completed-but-ineffective
# RRs detected via DataStorage hash chain and spec_drift analysis).
#
# NOTE: This scenario MUST run sequentially (not in parallel with others).
# It temporarily lowers the gateway cooldownPeriod from 5m to 1m so that
# re-fired alerts are processed quickly enough for 3 escalation cycles to
# complete within the timeout window.
#
# Prerequisites:
#   - Kind cluster with Kubernaut platform deployed
#   - Prometheus with kube-state-metrics
#
# Usage: ./scenarios/memory-escalation/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-memory-escalation"

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

echo "============================================="
echo " Memory Escalation Demo (#168)"
echo " OOMKill -> Increase Limits -> Repeat -> Escalate"
echo "============================================="
echo ""

# Step 0: Clean up stale alerts/RRs from any previous run (#193)
ensure_clean_slate "${NAMESPACE}"

# Enable KA Prometheus toolset for this scenario (kubernaut#473, #108).
echo "==> Enabling Kubernaut Agent Prometheus toolset for this scenario..."
enable_prometheus_toolset
force_production_approval
echo ""

# Lower gateway deduplication cooldown so re-fired alerts aren't suppressed
# for 5m between cycles. Restored in cleanup trap below.
_ORIG_COOLDOWN=$(kubectl get cm gateway-config -n "${PLATFORM_NS}" \
  -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
  | grep 'cooldownPeriod' | awk '{print $2}' || echo "5m")
_restore_cooldown() {
    echo "==> Restoring gateway cooldownPeriod to ${_ORIG_COOLDOWN}..."
    kubectl get cm gateway-config -n "${PLATFORM_NS}" -o json 2>/dev/null \
      | python3 -c "
import sys, json, re
cm = json.load(sys.stdin)
cfg = cm['data']['config.yaml']
cfg = re.sub(r'cooldownPeriod:.*', 'cooldownPeriod: ${_ORIG_COOLDOWN}', cfg)
cm['data']['config.yaml'] = cfg
json.dump(cm, sys.stdout)
" | kubectl apply -f - >/dev/null 2>&1
    kubectl rollout restart deployment/gateway -n "${PLATFORM_NS}" >/dev/null 2>&1
    kubectl rollout status deployment/gateway -n "${PLATFORM_NS}" --timeout=60s >/dev/null 2>&1 || true
}
trap '_restore_cooldown' EXIT

echo "==> Lowering gateway cooldownPeriod to 1m for escalation cycles..."
kubectl get cm gateway-config -n "${PLATFORM_NS}" -o json 2>/dev/null \
  | python3 -c "
import sys, json, re
cm = json.load(sys.stdin)
cfg = cm['data']['config.yaml']
cfg = re.sub(r'cooldownPeriod:.*', 'cooldownPeriod: 1m', cfg)
cm['data']['config.yaml'] = cfg
json.dump(cm, sys.stdout)
" | kubectl apply -f - >/dev/null 2>&1
kubectl rollout restart deployment/gateway -n "${PLATFORM_NS}" >/dev/null 2>&1
kubectl rollout status deployment/gateway -n "${PLATFORM_NS}" --timeout=60s
echo "  Gateway cooldownPeriod set to 1m (was ${_ORIG_COOLDOWN})."
echo ""

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Let the container run and get OOMKilled
echo "==> Step 2: Waiting for initial OOMKill (~1-2 min)..."
echo "  The ml-worker allocates 8Mi every 1s. With 64Mi limit, OOMKill in ~8s."
echo "  After OOMKill, Prometheus detects ContainerOOMKilling alert."
echo ""

# Step 3: Expected behavior
echo "==> Step 3: Pipeline in progress..."
echo ""
echo "  Expected multi-cycle flow:"
echo "    Cycle 1: OOMKill -> increase limits (64Mi -> 128Mi) -> OOMKill recurs"
echo "    Cycle 2: OOMKill -> increase limits (128Mi -> 256Mi) -> OOMKill recurs"
echo "    Cycle 3: RO blocks via CheckConsecutiveFailures (Failed RRs) or"
echo "             CheckIneffectiveRemediationChain (Completed-but-ineffective RRs)"
echo "             -> Escalates to human review (ManualReviewRequired)"
echo ""
echo "  The increase-memory-limits workflow DOES work (pods run longer), but the"
echo "  underlying memory leak means OOMKill always recurs. The platform recognizes"
echo "  the pattern and stops throwing automated remediation at it."
echo ""
# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
