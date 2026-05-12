#!/usr/bin/env bash
# Cleanup for Database Connection Saturation Demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Database Connection Saturation demo..."

echo "==> Disabling Kubernaut Agent Prometheus toolset..."
disable_prometheus_toolset || true

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule db-connection-saturation-rules -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete -f "${SCRIPT_DIR}/manifests/servicemonitor.yaml" --ignore-not-found
kubectl delete namespace demo-db-saturation --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-db-saturation &>/dev/null; do
  sleep 2
done

echo "==> Silencing stale alerts in AlertManager..."
silence_alert "DatabaseConnectionPoolExhausted" "demo-db-saturation" "2m"

purge_pipeline_crds

echo "==> Cleanup complete."
