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
require_demo_ready

echo "============================================="
echo " Memory Escalation Demo (#168)"
echo " OOMKill -> Increase Limits -> Repeat -> Escalate"
echo "============================================="
echo ""

# Enable HAPI Prometheus toolset for this scenario (kubernaut#473, #108).
echo "==> Enabling HolmesGPT Prometheus toolset for this scenario..."
helm upgrade kubernaut "${CHART_REF}" \
  -n "${PLATFORM_NS}" --reuse-values \
  --set holmesgptApi.prometheus.enabled=true \
  --wait --timeout 3m
echo ""

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Let the container run and get OOMKilled
echo "==> Step 2: Waiting for initial OOMKill (~1-2 min)..."
echo "  The ml-worker allocates 8Mi every 2s. With 64Mi limit, OOMKill in ~16s."
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
