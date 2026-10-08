#!/usr/bin/env bash
# Cleanup for Proactive Memory Exhaustion Demo (#129)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
if fleet_initialize_targeting "$@"; then
    # EM/toolset restoration, alert handling, and pipeline cleanup target the
    # hub; the leaking workload and monitoring resources target the spoke.
    # shellcheck source=../../scripts/platform-helper.sh
    source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
    restore_em || true
    disable_prometheus_toolset || true
    fleet_cleanup_scenario_resources "${SCRIPT_DIR}/manifests" demo-telemetry
    silence_alert "ContainerMemoryExhaustionPredicted" "demo-telemetry" "2m"
    purge_pipeline_crds
    exit 0
fi
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Memory Leak demo..."

echo "==> Restoring EM configuration..."
restore_em || true

echo "==> Disabling Kubernaut Agent Prometheus toolset..."
disable_prometheus_toolset || true

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-telemetry -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-telemetry --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-telemetry &>/dev/null; do
  sleep 2
done

echo "==> Silencing stale alerts in AlertManager..."
silence_alert "ContainerMemoryExhaustionPredicted" "demo-telemetry" "2m"

purge_pipeline_crds

echo "==> Cleanup complete."
