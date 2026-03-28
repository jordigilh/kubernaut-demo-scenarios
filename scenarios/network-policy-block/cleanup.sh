#!/usr/bin/env bash
# Cleanup for NetworkPolicy Traffic Block Demo (#138)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up NetworkPolicy Traffic Block demo..."

kubectl delete -f "${SCRIPT_DIR}/manifests/deny-all-netpol.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/networkpolicy-allow.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/deployment.yaml" --ignore-not-found
kubectl delete namespace demo-netpol --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-netpol &>/dev/null; do
  sleep 2
done

restart_alertmanager

echo "==> Cleanup complete."
