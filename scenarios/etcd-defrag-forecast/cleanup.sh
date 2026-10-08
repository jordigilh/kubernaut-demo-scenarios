#!/usr/bin/env bash
# Cleanup for etcd Defrag Forecast Demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
if fleet_initialize_targeting "$@"; then
    # Alert silencing and pipeline state are hub-side; the datastore workload
    # and its monitoring resources are removed from the spoke.
    # shellcheck source=../../scripts/platform-helper.sh
    source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
    fleet_cleanup_scenario_resources "${SCRIPT_DIR}/manifests" demo-datastore
    silence_alert "EtcdHighFragmentationRatio" "demo-datastore" "2m"
    purge_pipeline_crds
    exit 0
fi
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up etcd Defrag Forecast demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-datastore -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-datastore --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-datastore &>/dev/null; do
    sleep 2
done

echo "==> Silencing stale alerts in AlertManager..."
silence_alert "EtcdHighFragmentationRatio" "demo-datastore" "2m"

purge_pipeline_crds

echo "==> Cleanup complete."
