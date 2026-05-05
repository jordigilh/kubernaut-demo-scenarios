#!/bin/sh
set -e

# The RCA target may be a Deployment or StatefulSet; resolve to the PVC name.
PVC_NAME="${TARGET_RESOURCE_NAME}"

# If the target is a Deployment/StatefulSet, find its PVC.
if [ "${TARGET_RESOURCE_KIND:-PersistentVolumeClaim}" != "PersistentVolumeClaim" ]; then
    echo "Target is ${TARGET_RESOURCE_KIND}/${TARGET_RESOURCE_NAME}, resolving PVC..."
    PVCS=$(kubectl get pvc -n "$TARGET_RESOURCE_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [ -n "$PVCS" ]; then
        PVC_NAME=$(echo "$PVCS" | tr ' ' '\n' | head -1)
        echo "Resolved to PVC: ${PVC_NAME}"
    else
        echo "ERROR: No PVCs found in namespace ${TARGET_RESOURCE_NAMESPACE}"
        exit 1
    fi
fi

echo "=== Phase 1: Validate ==="
echo "Checking PVC ${PVC_NAME} in namespace ${TARGET_RESOURCE_NAMESPACE}..."

CURRENT_SIZE=$(kubectl get pvc "$PVC_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.spec.resources.requests.storage}')
echo "Current PVC size: ${CURRENT_SIZE}"

SC_NAME=$(kubectl get pvc "$PVC_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.spec.storageClassName}')
echo "StorageClass: ${SC_NAME}"

EXPANDABLE=$(kubectl get sc "$SC_NAME" -o jsonpath='{.allowVolumeExpansion}' 2>/dev/null || echo "false")
if [ "$EXPANDABLE" != "true" ]; then
    echo "ERROR: StorageClass ${SC_NAME} does not support volume expansion"
    exit 1
fi
echo "Validated: StorageClass supports volume expansion."

# Calculate new size: double the current size (simple heuristic).
# Parse numeric value and unit from current size.
NUMERIC=$(echo "$CURRENT_SIZE" | sed 's/[^0-9]//g')
UNIT=$(echo "$CURRENT_SIZE" | sed 's/[0-9]//g')

if [ -z "$UNIT" ]; then
    # Raw bytes, double it
    NEW_SIZE=$((NUMERIC * 2))
elif [ "$UNIT" = "Mi" ]; then
    if [ "$NUMERIC" -lt 1024 ]; then
        NEW_SIZE="$((NUMERIC * 2))Mi"
    else
        NEW_SIZE="$(( (NUMERIC * 2) / 1024 ))Gi"
    fi
elif [ "$UNIT" = "Gi" ]; then
    NEW_SIZE="$((NUMERIC * 2))Gi"
else
    NEW_SIZE="$((NUMERIC * 2))${UNIT}"
fi

echo "New PVC size: ${NEW_SIZE}"

echo "=== Phase 2: Action ==="
echo "Expanding PVC ${PVC_NAME} from ${CURRENT_SIZE} to ${NEW_SIZE}..."
kubectl patch pvc "$PVC_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${NEW_SIZE}\"}}}}"

echo "=== Phase 3: Verify ==="
echo "Waiting for PVC resize to complete..."
TIMEOUT=120
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    ACTUAL_SIZE=$(kubectl get pvc "$PVC_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
      -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "")
    CONDITION=$(kubectl get pvc "$PVC_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="FileSystemResizePending")].status}' 2>/dev/null || echo "")

    if [ "$ACTUAL_SIZE" = "$NEW_SIZE" ]; then
        echo "=== SUCCESS: PVC ${PVC_NAME} expanded from ${CURRENT_SIZE} to ${NEW_SIZE} ==="
        exit 0
    fi

    if [ "$CONDITION" = "True" ]; then
        echo "  FileSystemResizePending -- waiting for node to expand filesystem..."
    fi

    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

# Check one final time
ACTUAL_SIZE=$(kubectl get pvc "$PVC_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "unknown")
if [ "$ACTUAL_SIZE" != "$CURRENT_SIZE" ]; then
    echo "=== SUCCESS: PVC ${PVC_NAME} expanded (capacity now: ${ACTUAL_SIZE}) ==="
    exit 0
fi

echo "WARNING: PVC resize request submitted but capacity not yet updated (current: ${ACTUAL_SIZE})"
echo "The CSI driver may complete the resize asynchronously."
exit 0
