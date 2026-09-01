#!/usr/bin/env bash
# PVC Capacity Forecast Demo -- Fleet Spoke Steps
#
# Deploys data-service (data-writer sidecar fills the PVC on its own -- no
# separate inject script) against SPOKE_KUBECONFIG. Touches only the
# spoke -- safe to invoke directly, multiple times, once per spoke cluster
# if demoing across several spokes. Run ../fleet/hub.sh afterward (once
# all spokes are done) to confirm the alert(s) reached the hub's
# Alertmanager, or use ../run.sh which runs both in order for the common
# single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-archive"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_ensure_kube_state_metrics
fleet_ensure_kubelet_metrics_job "kubelet-volume-stats" \
  'kubelet_volume_stats_(used_bytes|capacity_bytes)'
fleet_load_prometheus_rule "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"
fleet_reload_spoke_prometheus

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
