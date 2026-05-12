#!/usr/bin/env bash
# PVC Capacity Forecast Demo -- Automated Runner
# PoC for Kubernaut as the action layer for RHACM capacity forecasting.
#
# A data-writer sidecar fills a 512Mi PVC at ~5MB/min, simulating
# post-migration data growth. predict_linear projects exhaustion within
# 1 hour, triggering PVRunwayShort. The LLM investigates the growth
# source, checks StorageClass expansion capability, and selects
# ExpandPersistentVolumeClaim to resize the PVC.
#
# Prerequisites:
#   - OCP cluster with Kubernaut services
#   - StorageClass with allowVolumeExpansion: true (lvms-vg1)
#   - Prometheus scraping kubelet volume metrics
#
# Usage: ./scenarios/pvc-capacity-forecast/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-pvc-forecast"

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
echo " PVC Capacity Forecast Demo (RHACM PoC)"
echo "============================================="
echo ""

# Preflight: verify that at least one StorageClass supports volume expansion.
echo "==> Preflight: Checking StorageClass expansion support..."
SC_NAME=$(kubectl get sc -o jsonpath='{.items[?(@.allowVolumeExpansion==true)].metadata.name}' 2>/dev/null | awk '{print $1}')
if [ -z "${SC_NAME}" ]; then
    echo "ERROR: No StorageClass with allowVolumeExpansion: true found."
    echo "  This scenario requires a CSI-backed StorageClass that supports online volume expansion."
    exit 1
fi
echo "  StorageClass ${SC_NAME}: allowVolumeExpansion=true"
echo ""

# Enable KA Prometheus toolset so the LLM can investigate growth trends.
echo "==> Enabling Kubernaut Agent Prometheus toolset for this scenario..."
enable_prometheus_toolset
echo ""

# PVCs with LVMS finalizers can block namespace termination for minutes.
# Strip finalizers before ensure_clean_slate so the namespace can terminate.
if kubectl get ns "${NAMESPACE}" &>/dev/null; then
    for _pvc in $(kubectl get pvc -n "${NAMESPACE}" -o name 2>/dev/null); do
        kubectl patch "${_pvc}" -n "${NAMESPACE}" --type=json \
          -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    done
    kubectl delete pvc --all -n "${NAMESPACE}" --force --grace-period=0 2>/dev/null || true
fi

ensure_clean_slate "${NAMESPACE}"

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for deployment to be healthy
echo "==> Step 2: Waiting for data-service to be ready..."
kubectl wait --for=condition=Available deployment/data-service \
  -n "${NAMESPACE}" --timeout=180s
echo "  data-service is running."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 3: Verify PVC is bound
echo "==> Step 3: Verifying PVC is bound..."
for _i in $(seq 1 30); do
    PVC_STATUS=$(kubectl get pvc data-service-data -n "${NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "${PVC_STATUS}" = "Bound" ] && break
    sleep 2
done
if [ "${PVC_STATUS}" != "Bound" ]; then
    echo "ERROR: PVC data-service-data is not Bound (status: ${PVC_STATUS})"
    exit 1
fi
PVC_SIZE=$(kubectl get pvc data-service-data -n "${NAMESPACE}" \
  -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "unknown")
echo "  PVC data-service-data: Bound (${PVC_SIZE})"
echo ""

echo "==> Step 4: Data writer filling PVC at ~5MB/min."
echo "    predict_linear will fire once it projects exhaustion within 1 hour,"
echo "    typically after 5-7 minutes of trend data."

# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}" || _rc=$?
fi

exit "${_rc:-0}"
