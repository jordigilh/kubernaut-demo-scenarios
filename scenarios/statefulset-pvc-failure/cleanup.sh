#!/usr/bin/env bash
# Cleanup for StatefulSet PVC Failure Demo (#137)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up StatefulSet PVC Failure demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-keystore -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete statefulset kv-store -n demo-keystore --cascade=foreground --ignore-not-found
kubectl delete pvc -l app=kv-store -n demo-keystore --ignore-not-found
kubectl delete namespace demo-keystore --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while kubectl get ns demo-keystore &>/dev/null; do
  sleep 2
  _elapsed=$((_elapsed + 2))
  if [ "$_elapsed" -ge 120 ]; then
    echo "  WARNING: Namespace demo-keystore still terminating after 120s, proceeding..."
    break
  fi
done

restart_alertmanager

purge_pipeline_crds

echo "==> Cleanup complete."
