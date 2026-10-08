#!/usr/bin/env bash
# Cluster Autoscaling Demo -- Fleet Spoke Steps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-loadtest"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

if [ "$(detect_spoke_platform)" != "kind" ]; then
    echo "ERROR: autoscale Fleet mode currently supports only a Kind spoke." >&2
    exit 1
fi
if ! kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get apiservice v1beta1.metrics.k8s.io \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q True; then
    echo "ERROR: metrics-server is unavailable on the spoke; autoscale RCA requires the Metrics API." >&2
    exit 1
fi

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${MANIFEST_DIR}"
kubectl_workload wait --for=condition=Available deployment/web-cluster \
    -n "${NAMESPACE}" --timeout=120s

# The provisioner watches the target cluster's ScaleRequest and joins the new
# node to that same Kind cluster. Keep it alive while the hub drives WFE.
echo "==> [spoke] Starting the host-side provisioner against the spoke..."
PROVISIONER_LOG="${FLEET_AUTOSCALE_PROVISIONER_LOG:-${TMPDIR:-/tmp}/kubernaut-autoscale-fleet-provisioner.log}"
PROVISIONER_PID_FILE="${FLEET_AUTOSCALE_PROVISIONER_PID_FILE:-${TMPDIR:-/tmp}/kubernaut-autoscale-fleet-provisioner.pid}"
nohup env KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/provisioner.sh" \
    >"${PROVISIONER_LOG}" 2>&1 < /dev/null &
printf '%s\n' "$!" > "${PROVISIONER_PID_FILE}"
echo "  Provisioner PID: $(cat "${PROVISIONER_PID_FILE}") (log: ${PROVISIONER_LOG})"

POD_REQUEST_MI=2048
TOTAL_ALLOC_KI=$(kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get nodes \
    -l kubernaut.ai/managed=true \
    -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' \
    | sed 's/Ki$//' | awk '{s+=$1} END {printf "%.0f", s}')
TOTAL_ALLOC_MI=$((TOTAL_ALLOC_KI / 1024))
MAX_PODS=$((TOTAL_ALLOC_MI / POD_REQUEST_MI))
PENDING_EXTRA="${PENDING_EXTRA:-1}"
REPLICAS=$((MAX_PODS + PENDING_EXTRA))
[ "${REPLICAS}" -lt 6 ] && REPLICAS=6

echo "==> [spoke] Scaling web-cluster to ${REPLICAS} replicas to create Pending pods..."
kubectl_workload scale deployment/web-cluster --replicas="${REPLICAS}" -n "${NAMESPACE}"
sleep 15
kubectl_workload get pods -n "${NAMESPACE}" -o wide
