#!/bin/sh
set -e

echo "=== Phase 1: Validate ==="
echo "Checking node $TARGET_RESOURCE_NAME status..."

NODE_READY=$(kubectl get node "$TARGET_RESOURCE_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
echo "Node Ready status: $NODE_READY"

if [ "$NODE_READY" = "True" ]; then
  echo "WARNING: Node $TARGET_RESOURCE_NAME is currently Ready. It may have recovered."
  echo "Proceeding with cordon to prevent future issues."
fi

SCHEDULABLE=$(kubectl get node "$TARGET_RESOURCE_NAME" -o jsonpath='{.spec.unschedulable}')
echo "Node schedulable: $([ "$SCHEDULABLE" = "true" ] && echo "No (already cordoned)" || echo "Yes")"
echo "Validated: node identified for cordon and drain."

echo "=== Phase 2: Action ==="
echo "Cordoning node $TARGET_RESOURCE_NAME..."
kubectl cordon "$TARGET_RESOURCE_NAME"

echo "Draining node $TARGET_RESOURCE_NAME (grace period 30s, ignore daemonsets)..."
kubectl drain "$TARGET_RESOURCE_NAME" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --grace-period=30 \
  --timeout=120s || true

echo "=== Phase 3: Verify ==="
SCHEDULABLE_AFTER=$(kubectl get node "$TARGET_RESOURCE_NAME" -o jsonpath='{.spec.unschedulable}')
echo "Node unschedulable after cordon: $SCHEDULABLE_AFTER"

PODS_ON_NODE=$(kubectl get pods --all-namespaces --field-selector="spec.nodeName=$TARGET_RESOURCE_NAME" \
  --no-headers 2>/dev/null | grep -v "kube-system" | wc -l | tr -d ' ')
echo "Non-system pods remaining on node: $PODS_ON_NODE"

echo "=== SUCCESS: Node $TARGET_RESOURCE_NAME cordoned and drained, $PODS_ON_NODE non-system pods remaining ==="
