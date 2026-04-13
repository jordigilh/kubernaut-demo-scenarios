#!/usr/bin/env bash
# Add a NoSchedule taint to the designated taint-target worker node.
# Only one worker is tainted so that WFE remediation jobs can still schedule
# on the other untainted worker.
set -euo pipefail

TARGET_NODE=$(kubectl get nodes -l kubernaut.ai/demo-taint-target=true -o name 2>/dev/null | head -1)

if [ -z "$TARGET_NODE" ]; then
  echo "  No node with label kubernaut.ai/demo-taint-target=true found. Auto-labeling a worker..."
  WORKER=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o name 2>/dev/null | head -1)
  if [ -z "$WORKER" ]; then
    echo "ERROR: No worker nodes available to label."
    exit 1
  fi
  kubectl label "$WORKER" kubernaut.ai/demo-taint-target=true
  TARGET_NODE="$WORKER"
fi

echo "==> Adding NoSchedule taint to ${TARGET_NODE}..."
kubectl taint nodes "${TARGET_NODE}" maintenance=scheduled:NoSchedule --overwrite

echo "==> Taint applied to ${TARGET_NODE}. Pods pinned to this node will remain Pending."
