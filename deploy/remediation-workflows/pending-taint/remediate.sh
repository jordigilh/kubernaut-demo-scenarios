#!/bin/sh
set -e

: "${TAINT_KEY:?TAINT_KEY is required}"

if [ -z "${NODE_NAME:-}" ]; then
  echo "NODE_NAME not provided. Discovering tainted node from cluster..."
  NODE_NAME=$(kubectl get nodes -o jsonpath="{range .items[*]}{.metadata.name} {range .spec.taints[*]}{.key} {end}{'\\n'}{end}" 2>/dev/null \
    | grep "${TAINT_KEY}" | head -1 | awk '{print $1}')
  if [ -z "${NODE_NAME}" ]; then
    echo "ERROR: No node found with taint '${TAINT_KEY}'"
    exit 1
  fi
  echo "Discovered node: ${NODE_NAME}"
fi

echo "=== Phase 1: Validate ==="
echo "Checking node ${NODE_NAME} for taint ${TAINT_KEY}..."

TAINTS=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.spec.taints[*].key}')
echo "Current taints: $TAINTS"

if ! echo "$TAINTS" | grep -q "${TAINT_KEY}"; then
  echo "WARNING: Taint '${TAINT_KEY}' not found on node ${NODE_NAME}"
  echo "Available taints: $TAINTS"
  echo "Proceeding anyway -- taint may have already been removed."
fi

NODE_STATUS=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
echo "Node Ready status: $NODE_STATUS"
echo "Validated: node exists and taint identified."

echo "=== Phase 2: Action ==="
echo "Removing taint ${TAINT_KEY} from node ${NODE_NAME}..."
kubectl taint nodes "${NODE_NAME}" "${TAINT_KEY}-" || true

echo "Waiting for pending pods to be scheduled (30s)..."
sleep 30

echo "=== Phase 3: Verify ==="
REMAINING_TAINTS=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.spec.taints[*].key}')
echo "Remaining taints: ${REMAINING_TAINTS:-<none>}"

if echo "$REMAINING_TAINTS" | grep -q "${TAINT_KEY}"; then
  echo "ERROR: Taint '${TAINT_KEY}' still present on ${NODE_NAME} after removal attempt"
  exit 1
fi

if [ -n "${TARGET_RESOURCE_NAMESPACE:-}" ]; then
  PENDING=$(kubectl get pods -n "$TARGET_RESOURCE_NAMESPACE" --field-selector=status.phase=Pending \
    -o name 2>/dev/null | wc -l | tr -d ' ')
  echo "Pending pods in $TARGET_RESOURCE_NAMESPACE: $PENDING"

  if [ "$PENDING" -gt 0 ]; then
    echo "WARNING: $PENDING pods still Pending -- may need more time to schedule"
  fi
else
  echo "TARGET_RESOURCE_NAMESPACE not set; skipping namespace-level pod check."
fi

echo "=== SUCCESS: Taint '${TAINT_KEY}' removed from ${NODE_NAME} ==="
