#!/usr/bin/env bash
# Usage: ./scenarios/build-failure/run.sh [--auto-approve|--interactive] [--no-validate]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-build"

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

if ! command -v oc &>/dev/null; then
    echo "ERROR: oc is required for OpenShift build scenarios" >&2
    exit 1
fi

enable_prometheus_toolset
force_production_approval

echo "============================================="
echo " Build Failure Remediation Demo"
echo " Broken Git source -> build failure"
echo " -> FixBuildSource"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

echo "==> Step 2: Running baseline build..."
oc start-build webapp -n "${NAMESPACE}"
echo "  Waiting for baseline build to complete..."
BUILD_PHASE=""
for _i in $(seq 1 120); do
    BUILD_PHASE=$(kubectl get build webapp-1 -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "${BUILD_PHASE}" = "Complete" ]; then
        break
    fi
    if [ "${BUILD_PHASE}" = "Failed" ] || [ "${BUILD_PHASE}" = "Error" ]; then
        echo "ERROR: Baseline build failed with phase: ${BUILD_PHASE}" >&2
        exit 1
    fi
    sleep 5
done
if [ "${BUILD_PHASE}" != "Complete" ]; then
    echo "ERROR: Baseline build did not complete within timeout" >&2
    exit 1
fi
echo "  Baseline build completed successfully."

echo "==> Step 3: Establishing healthy baseline (20s)..."
sleep 20
echo ""

echo "==> Step 4: Injecting broken Git source..."
bash "${SCRIPT_DIR}/inject-broken-source.sh"
echo ""

echo "==> Step 5: Waiting for failing build and alert conditions..."
sleep 15
kubectl get builds -n "${NAMESPACE}"
echo ""
kubectl get pods -n "${NAMESPACE}"
echo ""

if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
