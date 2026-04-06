#!/usr/bin/env bash
# Duplicate Alert Suppression Demo -- Automated Runner
# Scenario #170: Alert storm (5 pods crash) -> Gateway deduplicates to 1 RR
#
# Demonstrates Gateway-level deduplication via OwnerResolver:
# All 5 pods belong to the same Deployment, so they share one fingerprint.
# 5 alerts arrive, but only 1 RemediationRequest is created (OccurrenceCount=5).
#
# Prerequisites:
#   - Kind or OCP cluster with Kubernaut services
#   - Prometheus with kube-state-metrics
#
# Usage: ./scenarios/duplicate-alert-suppression/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-alert-storm"

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
echo " Duplicate Alert Suppression Demo (#170)"
echo " 5 Crashing Pods -> 1 RemediationRequest"
echo "============================================="
echo ""

# Step 0: Clean up stale alerts/RRs from any previous run (#193)
ensure_clean_slate "${NAMESPACE}"

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for healthy deployment
echo "==> Step 2: Waiting for all 5 replicas to be healthy..."
kubectl wait --for=condition=Available deployment/api-gateway \
  -n "${NAMESPACE}" --timeout=120s
echo "  All 5 pods are running."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 3: Establish baseline
echo "==> Step 3: Establishing healthy baseline (20s)..."
sleep 20
echo ""

# Step 4: Inject bad config (all 5 pods crash)
echo "==> Step 4: Injecting invalid config (all 5 pods will CrashLoop)..."
bash "${SCRIPT_DIR}/inject-bad-config.sh"
echo ""
echo "  Waiting for pods to start crashing..."
sleep 10
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 5: Wait for alerts
echo "==> Step 5: Waiting for CrashLoop alerts to fire (~2-3 min)..."
echo "  5 pods are crashing, but they all belong to Deployment/api-gateway."
echo "  The Gateway OwnerResolver maps each pod alert to the Deployment."
echo "  All 5 alerts share fingerprint: SHA256(demo-alert-storm:deployment:api-gateway)"
echo ""

# Step 6: Expected deduplication behavior
echo "==> Step 6: Waiting for deduplication and pipeline..."
echo ""
echo "  Expected:"
echo "    - 1 RR created (NOT 5)"
echo "    - RR.status.deduplication.occurrenceCount increases to 5"
echo "    - Pipeline proceeds: AA -> RO -> WE (rollback) -> EM"
echo "    - All 5 pods recover after single rollback"

# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
