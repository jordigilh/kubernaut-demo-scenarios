#!/usr/bin/env bash
# Cleanup for Proactive Memory Exhaustion Demo (#129)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Memory Leak demo..."

echo "==> Restoring EM configuration..."
restore_em || true

echo "==> Disabling Kubernaut Agent Prometheus toolset..."
disable_prometheus_toolset || true

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace demo-memory-leak --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-memory-leak &>/dev/null; do
  sleep 2
done

echo "==> Silencing stale alerts in AlertManager..."
silence_alert "ContainerMemoryExhaustionPredicted" "demo-memory-leak" "2m"

purge_pipeline_crds

echo "==> Cleanup complete."
