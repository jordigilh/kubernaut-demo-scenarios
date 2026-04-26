#!/usr/bin/env bash
# Cleanup for PDB Deadlock Demo (#124)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

disable_prometheus_toolset || true
restore_production_approval || true

echo "==> Cleaning up PDB Deadlock demo..."

# Uncordon any cordoned worker nodes and remove the managed label
for node in $(kubectl get nodes -l kubernaut.ai/managed=true -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  echo "  Uncordoning and unlabelling worker node: ${node}..."
  kubectl uncordon "${node}" 2>/dev/null || true
  kubectl label node "${node}" kubernaut.ai/managed- 2>/dev/null || true
done

# Remove auto-applied label only (preserves pre-existing labels on Kind)
AUTO_LABEL_MARKER="/tmp/.pdb-deadlock-auto-labeled"
if [ -f "$AUTO_LABEL_MARKER" ]; then
  AUTO_NODE=$(cat "$AUTO_LABEL_MARKER")
  echo "  Removing auto-applied kubernaut.ai/managed label from ${AUTO_NODE}..."
  kubectl label "${AUTO_NODE}" kubernaut.ai/managed- 2>/dev/null || true
  rm -f "$AUTO_LABEL_MARKER"
fi

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace demo-pdb --ignore-not-found

purge_pipeline_crds

echo "==> Cleanup complete."
