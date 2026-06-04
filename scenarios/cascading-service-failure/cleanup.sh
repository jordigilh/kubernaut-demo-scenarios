#!/usr/bin/env bash
# Cleanup for Cascading Service Failure Demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Cascading Service Failure demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-order-fulfillment -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-order-fulfillment --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while kubectl get ns demo-order-fulfillment &>/dev/null; do
  sleep 2
  _elapsed=$((_elapsed + 2))
  if [ "$_elapsed" -ge 120 ]; then
    echo "  WARNING: Namespace demo-order-fulfillment still terminating after 120s, proceeding..."
    break
  fi
done

echo "==> Silencing stale alerts in AlertManager..."
silence_alert "KubePodCrashLooping" "demo-order-fulfillment" "2m"

purge_pipeline_crds

echo "==> Cleanup complete."
