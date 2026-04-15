#!/usr/bin/env bash
# Proactive Memory Exhaustion Demo -- Automated Runner
# Scenario #129: predict_linear detects OOM trend -> graceful restart
#
# The 'leaker' sidecar allocates ~1MB every 5 seconds (~12MB/min) via a
# memory-backed emptyDir. predict_linear projects OOM within 30 minutes,
# triggering ContainerMemoryExhaustionPredicted. The LLM selects
# GracefulRestart (rolling restart) to reset memory before OOM.
#
# Prerequisites:
#   - Kind or OCP cluster with Kubernaut services
#   - Prometheus with kube-state-metrics and cAdvisor scraping
#
# Usage: ./scenarios/memory-leak/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-memory-leak"

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
echo " Proactive Memory Exhaustion Demo (#129)"
echo "============================================="
echo ""

# Enable KA Prometheus toolset for this scenario (kubernaut#473, #108).
echo "==> Enabling Kubernaut Agent Prometheus toolset for this scenario..."
enable_prometheus_toolset
echo ""

ensure_clean_slate "${NAMESPACE}"

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for deployment to be healthy
echo "==> Step 2: Waiting for leaky-app to be ready..."
kubectl wait --for=condition=Available deployment/leaky-app \
  -n "${NAMESPACE}" --timeout=120s
echo "  leaky-app is running (2 pods with leaker sidecar)."
kubectl get pods -n "${NAMESPACE}"
echo ""

echo "==> Step 3: Memory leak building (~12MB/min per pod)."
echo "    predict_linear will fire once it projects OOM within 30 minutes,"
echo "    typically after 5-7 minutes of trend data."

# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
