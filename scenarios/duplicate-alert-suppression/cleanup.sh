#!/usr/bin/env bash
# Cleanup for Duplicate Alert Suppression Demo (#170)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

disable_prometheus_toolset || true

echo "==> Cleaning up Duplicate Alert Suppression demo..."

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace demo-alert-storm --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-alert-storm &>/dev/null; do
  sleep 2
done

restart_alertmanager

purge_pipeline_crds

echo "==> Cleanup complete."
