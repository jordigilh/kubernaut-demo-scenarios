#!/usr/bin/env bash
# Cleanup for Pending Pods Taint Removal Demo (#122)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
if fleet_initialize_targeting "$@"; then
    # shellcheck source=../../scripts/platform-helper.sh
    source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
    TARGET_NODE=$(fleet_target_kubectl get nodes -l kubernaut.ai/workload-pool=true \
        -o name 2>/dev/null | head -1 || true)
    [ -z "${TARGET_NODE}" ] || fleet_target_kubectl taint nodes "${TARGET_NODE}" maintenance- 2>/dev/null || true
    fleet_cleanup_scenario_resources "${SCRIPT_DIR}/manifests" demo-scheduler
    purge_pipeline_crds
    restart_alertmanager
    restore_em || true
    exit 0
fi

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Pending Taint demo..."

# Remove the injected taint from the taint-target worker node
TARGET_NODE=$(kubectl get nodes -l kubernaut.ai/workload-pool=true -o name 2>/dev/null | head -1)
if [ -n "$TARGET_NODE" ]; then
  echo "  Removing maintenance taint from ${TARGET_NODE}..."
  kubectl taint nodes "${TARGET_NODE}" maintenance- 2>/dev/null || true
fi

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-scheduler -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-scheduler --ignore-not-found

purge_pipeline_crds

echo "==> Restoring EM configuration..."
restore_em || true

echo "==> Cleanup complete."
