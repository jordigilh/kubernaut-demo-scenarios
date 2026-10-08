#!/usr/bin/env bash
# Cleanup for Red Herring / Multi-Incident Separation Demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
if fleet_initialize_targeting "$@"; then
    # Alerts and pipeline CRs are hub-side; the multi-service workload and
    # monitoring resources are removed from the spoke.
    # shellcheck source=../../scripts/platform-helper.sh
    source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
    fleet_cleanup_scenario_resources "${SCRIPT_DIR}/manifests" demo-microservices
    silence_alert "KubePodCrashLooping" "demo-microservices" "2m"
    silence_alert "ImagePullBackOffPersistent" "demo-microservices" "2m"
    purge_pipeline_crds
    exit 0
fi
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Red Herring / Multi-Incident demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-microservices -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-microservices --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-microservices &>/dev/null; do
  sleep 2
done

echo "==> Silencing stale alerts in AlertManager..."
silence_alert "KubePodCrashLooping" "demo-microservices" "2m"
silence_alert "ImagePullBackOffPersistent" "demo-microservices" "2m"

purge_pipeline_crds

echo "==> Cleanup complete."
