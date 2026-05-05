#!/usr/bin/env bash
# Cleanup for Red Herring / Multi-Incident Separation Demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Red Herring / Multi-Incident demo..."

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace demo-red-herring --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-red-herring &>/dev/null; do
  sleep 2
done

echo "==> Silencing stale alerts in AlertManager..."
silence_alert "KubePodCrashLooping" "demo-red-herring" "2m"
silence_alert "ImagePullBackOffPersistent" "demo-red-herring" "2m"

purge_pipeline_crds

echo "==> Cleanup complete."
