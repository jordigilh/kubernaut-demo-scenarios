#!/usr/bin/env bash
# SCC violation demo -- privileged SecurityContext -> SCC denial -> FixSecurityContext
#
# Prerequisites:
#   - Kind or OCP cluster with Kubernaut services
#   - Prometheus with kube-state-metrics scraping
#
# Usage: ./scenarios/scc-violation/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-scc"

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

echo "============================================="
echo " SCC Violation Remediation Demo"
echo " Privileged requirement -> SCC denial"
echo " -> FixSecurityContext"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

echo "==> Step 2: Waiting for healthy deployment..."
kubectl wait --for=condition=Available deployment/metrics-agent \
  -n "${NAMESPACE}" --timeout=120s
echo "  metrics-agent is running with SCC-compliant configuration."
kubectl get pods -n "${NAMESPACE}"
echo ""

echo "==> Step 3: Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established."
echo ""

echo "==> Step 4: Injecting privileged requirement (SCC violation)..."
bash "${SCRIPT_DIR}/inject-privileged-requirement.sh"
echo ""

echo "==> Step 5: Waiting for SCC denial and alert (~2 min)..."
echo "  The kubelet rejects pod creation due to SCC policy violation."
echo ""
sleep 10
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "  ReplicaSet events (look for SCC denial):"
kubectl get events -n "${NAMESPACE}" --field-selector reason=FailedCreate --sort-by='.lastTimestamp' 2>/dev/null | tail -5
echo ""
sleep 30
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""

if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
