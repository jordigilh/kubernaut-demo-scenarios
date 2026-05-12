#!/usr/bin/env bash
# Cleanup for PVC Capacity Forecast Demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up PVC Capacity Forecast demo..."

echo "==> Disabling Kubernaut Agent Prometheus toolset..."
disable_prometheus_toolset || true

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule pvc-capacity-forecast-rules -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete pvc --all -n demo-pvc-forecast --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete namespace demo-pvc-forecast --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while kubectl get ns demo-pvc-forecast &>/dev/null; do
  sleep 2
  _elapsed=$((_elapsed + 2))
  if [ "$_elapsed" -ge 120 ]; then
    echo "  WARNING: Namespace demo-pvc-forecast still terminating after 120s, proceeding..."
    break
  fi
done

echo "==> Silencing stale alerts in AlertManager..."
silence_alert "PVRunwayShort" "demo-pvc-forecast" "2m"

purge_pipeline_crds

echo "==> Cleanup complete."
