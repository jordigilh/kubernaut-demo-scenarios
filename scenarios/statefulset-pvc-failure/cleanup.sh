#!/usr/bin/env bash
# Cleanup for StatefulSet PVC Failure Demo (#137)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up StatefulSet PVC Failure demo..."

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete statefulset kv-store -n demo-statefulset --cascade=foreground --ignore-not-found
kubectl delete pvc -l app=kv-store -n demo-statefulset --ignore-not-found
kubectl delete namespace demo-statefulset --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while kubectl get ns demo-statefulset &>/dev/null; do
  sleep 2
  _elapsed=$((_elapsed + 2))
  if [ "$_elapsed" -ge 120 ]; then
    echo "  WARNING: Namespace demo-statefulset still terminating after 120s, proceeding..."
    break
  fi
done

restart_alertmanager

echo "==> Cleanup complete."
