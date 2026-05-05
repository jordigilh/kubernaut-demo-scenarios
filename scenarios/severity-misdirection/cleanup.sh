#!/usr/bin/env bash
# Cleanup for Severity Misdirection Demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Severity Misdirection demo..."

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace demo-severity-misdirection --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-severity-misdirection &>/dev/null; do
  sleep 2
done

echo "==> Silencing stale alerts in AlertManager..."
silence_alert "ContainerOOMKilling" "demo-severity-misdirection" "2m"
silence_alert "KubePodCrashLooping" "demo-severity-misdirection" "2m"

purge_pipeline_crds

echo "==> Cleanup complete."
