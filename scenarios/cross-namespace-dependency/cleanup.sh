#!/usr/bin/env bash
# Cleanup for Cross-Namespace Dependency Tracing Demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Cross-Namespace Dependency demo..."

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found

for ns in demo-xns-app demo-xns-infra; do
    kubectl delete namespace "${ns}" --ignore-not-found --wait=true
done

echo "==> Waiting for namespace deletion to complete..."
for ns in demo-xns-app demo-xns-infra; do
    while kubectl get ns "${ns}" &>/dev/null; do
        sleep 2
    done
done

echo "==> Silencing stale alerts in AlertManager..."
silence_alert "KubePodCrashLooping" "demo-xns-app" "2m"

purge_pipeline_crds

echo "==> Cleanup complete."
