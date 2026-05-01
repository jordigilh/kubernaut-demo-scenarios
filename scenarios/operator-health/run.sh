#!/usr/bin/env bash
# Usage: ./scenarios/operator-health/run.sh [--auto-approve|--interactive] [--no-validate]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-operator"

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
echo " Operator Health Remediation Demo"
echo " CSV deleted -> operator down"
echo " -> RestoreOperatorCSV"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

echo "==> Step 2: Waiting for InstallPlan..."
IP_NAME=""
for _i in $(seq 1 60); do
    IP_NAME=$(kubectl get installplan -n "${NAMESPACE}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
    if [ -n "${IP_NAME}" ]; then
        break
    fi
    sleep 5
done
if [ -z "${IP_NAME}" ]; then
    echo "ERROR: No InstallPlan created within timeout" >&2
    exit 1
fi
echo "  Approving InstallPlan ${IP_NAME}..."
kubectl patch installplan "${IP_NAME}" -n "${NAMESPACE}" --type=merge -p '{"spec":{"approved":true}}'

echo "==> Step 3: Waiting for operator CSV to reach Succeeded..."
CSV_PHASE=""
for _i in $(seq 1 60); do
    CSV_PHASE=$(kubectl get csv -n "${NAMESPACE}" --no-headers -o custom-columns=PHASE:.status.phase 2>/dev/null | grep -v "^$" | head -1)
    if [ "${CSV_PHASE}" = "Succeeded" ]; then
        break
    fi
    sleep 5
done
if [ "${CSV_PHASE}" != "Succeeded" ]; then
    echo "ERROR: CSV did not reach Succeeded within timeout (current: ${CSV_PHASE})" >&2
    exit 1
fi
echo "  Operator CSV is Succeeded."

echo "==> Step 4: Establishing healthy baseline (20s)..."
sleep 20
echo ""

echo "==> Step 5: Deleting CSV to trigger OperatorCSVFailed..."
bash "${SCRIPT_DIR}/inject-broken-csv.sh"
echo ""

kubectl get csv -n "${NAMESPACE}" 2>/dev/null || true
kubectl get pods -n "${NAMESPACE}" 2>/dev/null || true
echo ""

if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
