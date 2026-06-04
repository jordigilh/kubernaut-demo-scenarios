#!/usr/bin/env bash
# Cleanup for Operator OOMKill Informer Cache Flooding scenario
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Operator OOMKill Informer demo..."

kubectl delete prometheusrule demo-controllers-rules -n openshift-monitoring --ignore-not-found
kubectl delete namespace demo-controllers --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while kubectl get ns demo-controllers &>/dev/null; do
    sleep 2
    _elapsed=$((_elapsed + 2))
    if [ "$_elapsed" -ge 120 ]; then
        echo "  WARNING: Namespace still terminating after 120s, proceeding..."
        break
    fi
done

purge_pipeline_crds

echo "==> Cleanup complete."
