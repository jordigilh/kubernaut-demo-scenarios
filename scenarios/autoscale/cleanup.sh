#!/usr/bin/env bash
# Cleanup for Cluster Autoscaling Demo (#126)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
if fleet_initialize_targeting "$@"; then
    # shellcheck source=../../scripts/platform-helper.sh
    source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
    disable_prometheus_toolset || true
    fleet_target_kubectl delete cm scale-request -n "${PLATFORM_NS}" --ignore-not-found 2>/dev/null || true
    for node in $(fleet_target_kubectl get nodes -o name 2>/dev/null | grep 'worker-[0-9]' || true); do
        node_name="${node#node/}"
        fleet_target_kubectl drain "${node_name}" --ignore-daemonsets --delete-emptydir-data --force 2>/dev/null || true
        fleet_target_kubectl delete node "${node_name}" --ignore-not-found 2>/dev/null || true
        podman rm -f "${node_name}" 2>/dev/null || true
    done
    kubectl --kubeconfig="${HUB_KUBECONFIG}" delete cm scale-request -n "${PLATFORM_NS}" --ignore-not-found 2>/dev/null || true
    fleet_cleanup_scenario_resources "${SCRIPT_DIR}/manifests" demo-loadtest
    purge_pipeline_crds
    restart_alertmanager
    exit 0
fi

echo "==> Cleaning up Cluster Autoscaling demo..."

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
echo "==> Disabling Kubernaut Agent Prometheus toolset..."
disable_prometheus_toolset || true

# Kill any running provisioner agent
if pgrep -f "provisioner.sh" >/dev/null 2>&1; then
  echo "  Stopping provisioner agent..."
  pkill -f "provisioner.sh" || true
fi

# Delete the scale-request ConfigMap
kubectl delete cm scale-request -n "${PLATFORM_NS}" --ignore-not-found

# Check if a dynamically provisioned node exists and remove it
EXTRA_NODES=$(kubectl get nodes -o name 2>/dev/null | grep "worker-[0-9]" || true)
for NODE in $EXTRA_NODES; do
  NODE_NAME="${NODE#node/}"
  echo "  Removing dynamically provisioned node: $NODE_NAME"
  kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --force 2>/dev/null || true
  kubectl delete node "$NODE_NAME" --ignore-not-found
  podman rm -f "$NODE_NAME" 2>/dev/null || true
done

# Delete namespace and Prometheus rules
if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-loadtest -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-loadtest --ignore-not-found

purge_pipeline_crds

echo "==> Cleanup complete."
