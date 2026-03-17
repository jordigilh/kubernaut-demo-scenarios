#!/usr/bin/env bash
# Cleanup for Orphaned PVC Demo (#122)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Orphaned PVC demo..."

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace demo-orphaned-pvc --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-orphaned-pvc &>/dev/null; do
  sleep 2
done

# B15: Restore cleanup-pvc-v1 workflow if it was removed during run.sh.
if ! kubectl get remediationworkflow cleanup-pvc-v1 -n "${PLATFORM_NS}" &>/dev/null; then
    local_schema="${REPO_ROOT}/deploy/remediation-workflows/orphaned-pvc-no-action/orphaned-pvc-no-action.yaml"
    if [ -f "${local_schema}" ]; then
        echo "==> B15: Restoring cleanup-pvc-v1 workflow..."
        kubectl apply -f "${local_schema}"
    fi
fi

# Restart AlertManager so stale alert groups (repeat_interval=1h) don't
# suppress the fresh webhook notification for the new deployment.
restart_alertmanager

echo "==> Cleanup complete."
