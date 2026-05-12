#!/usr/bin/env bash
# Cleanup for Pending Pods Taint Removal Demo (#122)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Pending Taint demo..."

# Remove the injected taint from the taint-target worker node
TARGET_NODE=$(kubectl get nodes -l kubernaut.ai/demo-taint-target=true -o name 2>/dev/null | head -1)
if [ -n "$TARGET_NODE" ]; then
  echo "  Removing maintenance taint from ${TARGET_NODE}..."
  kubectl taint nodes "${TARGET_NODE}" maintenance- 2>/dev/null || true
fi

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule kubernaut-pending-taint-rules -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-taint --ignore-not-found

purge_pipeline_crds

echo "==> Restoring EM configuration..."
restore_em || true

echo "==> Cleanup complete."
