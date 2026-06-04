#!/usr/bin/env bash
# Cleanup for SLO Error Budget Burn Demo (#128)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Cleaning up SLO Error Budget Burn demo..."

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
echo "==> Disabling Kubernaut Agent Prometheus toolset..."
disable_prometheus_toolset || true
restore_production_approval || true

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-api --ignore-not-found

purge_pipeline_crds

echo "==> Cleanup complete."
