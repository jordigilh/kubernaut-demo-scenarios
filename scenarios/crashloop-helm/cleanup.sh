#!/usr/bin/env bash
# Cleanup for Helm CrashLoopBackOff Demo (#135)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

disable_prometheus_toolset || true
restore_production_approval || true

echo "==> Cleaning up Helm CrashLoopBackOff demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
helm uninstall demo-storefront -n demo-storefront 2>/dev/null || true
kubectl delete namespace demo-storefront --ignore-not-found

purge_pipeline_crds

echo "==> Cleanup complete."
