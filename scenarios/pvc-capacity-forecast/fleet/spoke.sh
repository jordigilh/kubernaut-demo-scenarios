#!/usr/bin/env bash
# PVC Capacity Forecast Demo -- Fleet Spoke Steps
#
# Deploys data-service (data-writer sidecar fills the PVC on its own -- no
# separate inject script) against SPOKE_KUBECONFIG. Monitoring is
# operator-native: the spoke's operator kubelet scrape already covers
# kubelet_volume_stats_* (no ScrapeConfig needed -- volume series appear
# once the PVC is bound and mounted), and the PrometheusRule is applied
# as-is. Touches only the spoke -- safe to invoke
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-archive"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${MANIFEST_DIR}"

echo "==> [spoke] Waiting for data-service to be ready..."
kubectl_workload wait --for=condition=Available deployment/data-service \
  -n "${NAMESPACE}" --timeout=180s
echo "  data-service is running."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Verifying PVC is bound..."
PVC_STATUS=""
for _i in $(seq 1 30); do
    PVC_STATUS=$(kubectl_workload get pvc data-service-data -n "${NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ "${PVC_STATUS}" = "Bound" ] && break
    sleep 2
done
if [ "${PVC_STATUS}" != "Bound" ]; then
    echo "ERROR: PVC data-service-data is not Bound (status: ${PVC_STATUS})" >&2
    exit 1
fi
PVC_SIZE=$(kubectl_workload get pvc data-service-data -n "${NAMESPACE}" \
  -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "unknown")
echo "  PVC data-service-data: Bound (${PVC_SIZE})"
echo ""

echo "==> [spoke] Data writer filling PVC at ~5MB/min."
echo "    predict_linear will fire once it projects exhaustion within 1 hour,"
echo "    typically after 5-7 minutes of trend data."
echo ""
echo "==> [spoke] Fault self-injecting. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
