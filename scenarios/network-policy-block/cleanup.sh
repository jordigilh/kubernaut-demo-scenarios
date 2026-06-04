#!/usr/bin/env bash
# Cleanup for NetworkPolicy Traffic Block Demo (#138)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up NetworkPolicy Traffic Block demo..."

kubectl delete -f "${SCRIPT_DIR}/manifests/deny-all-netpol.yaml" --ignore-not-found
if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete -f "${SCRIPT_DIR}/manifests/networkpolicy-allow.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/deployment.yaml" --ignore-not-found
kubectl delete namespace demo-frontend --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while kubectl get ns demo-frontend &>/dev/null; do
  sleep 2
  _elapsed=$((_elapsed + 2))
  if [ "$_elapsed" -ge 120 ]; then
    echo "  WARNING: Namespace demo-frontend still terminating after 120s, proceeding..."
    break
  fi
done

restart_alertmanager

purge_pipeline_crds

echo "==> Cleanup complete."
