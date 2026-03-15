#!/usr/bin/env bash
# Cleanup for Node NotReady Demo (#127)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Node NotReady demo..."

# Restore the paused worker node
WORKER_NODE=$(kubectl get nodes -l kubernaut.ai/managed=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$WORKER_NODE" ]; then
  echo "  Unpausing worker node: $WORKER_NODE"
  podman unpause "$WORKER_NODE" 2>/dev/null || true
  echo "  Uncordoning worker node: $WORKER_NODE"
  kubectl uncordon "$WORKER_NODE" 2>/dev/null || true
fi

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace demo-node --ignore-not-found

# Remove Kubernaut signal labels from the target node
if [ -n "$WORKER_NODE" ]; then
    echo "  Removing Kubernaut labels from node: ${WORKER_NODE}"
    kubectl label node "$WORKER_NODE" \
        kubernaut.ai/environment- \
        kubernaut.ai/business-unit- \
        kubernaut.ai/service-owner- \
        kubernaut.ai/criticality- \
        kubernaut.ai/sla-tier- 2>/dev/null || true
fi

echo "==> Cleanup complete."
