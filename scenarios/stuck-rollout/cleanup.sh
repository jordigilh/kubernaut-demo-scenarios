#!/usr/bin/env bash
# Cleanup for Stuck Rollout Demo (#130)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
if fleet_initialize_targeting "$@"; then
    # Rollout workload and monitoring resources are spoke-side; approval,
    # Alertmanager, and pipeline state are hub-side.
    # shellcheck source=../../scripts/platform-helper.sh
    source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
    restore_production_approval || true
    fleet_cleanup_scenario_resources "${SCRIPT_DIR}/manifests" demo-shipping
    restart_alertmanager
    purge_pipeline_crds
    exit 0
fi
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

restore_production_approval || true

echo "==> Cleaning up Stuck Rollout demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-shipping -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-shipping --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while kubectl get ns demo-shipping &>/dev/null; do
  sleep 2
  _elapsed=$((_elapsed + 2))
  if [ "$_elapsed" -ge 120 ]; then
    echo "  WARNING: Namespace demo-shipping still terminating after 120s, proceeding..."
    break
  fi
done

restart_alertmanager

purge_pipeline_crds

echo "==> Cleanup complete."
