#!/bin/sh
set -e

# Scale-Replicas workflow: scale a Deployment to a target replica count.
# Default: scale to 0 (isolate the offending workload).
#
# Environment variables (injected by WFE controller):
#   TARGET_RESOURCE_NAMESPACE - namespace of the target
#   TARGET_RESOURCE_NAME      - name of the Deployment
#   TARGET_RESOURCE_KIND      - must be Deployment
#   SCALE_REPLICAS            - desired replica count (default: 0)

SCALE_TO="${SCALE_REPLICAS:-0}"

if ! kubectl get "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" >/dev/null 2>&1; then
  OWNER=$(kubectl get replicaset "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
    -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}' 2>/dev/null || true)
  if [ -n "$OWNER" ]; then
    echo "WARN: '$TARGET_RESOURCE_NAME' is a ReplicaSet, resolved to Deployment '$OWNER'"
    TARGET_RESOURCE_NAME="$OWNER"
  fi
fi

echo "=== Phase 1: Validate ==="
CURRENT=$(kubectl get "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.spec.replicas}')
echo "Deployment: $TARGET_RESOURCE_NAME (ns: $TARGET_RESOURCE_NAMESPACE)"
echo "Current replicas: $CURRENT"
echo "Target replicas:  $SCALE_TO"

if [ "$CURRENT" = "$SCALE_TO" ]; then
  echo "Already at target replica count. Nothing to do."
  exit 0
fi

echo "=== Phase 2: Scale ==="
kubectl scale "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  --replicas="$SCALE_TO"

if [ "$SCALE_TO" -eq 0 ]; then
  echo "Scaled to 0. Waiting for pods to terminate..."
  kubectl wait --for=delete pod -l "app=$TARGET_RESOURCE_NAME" \
    -n "$TARGET_RESOURCE_NAMESPACE" --timeout=60s 2>/dev/null || true
else
  echo "Waiting for rollout..."
  kubectl rollout status "deployment/$TARGET_RESOURCE_NAME" \
    -n "$TARGET_RESOURCE_NAMESPACE" --timeout=120s
fi

echo "=== Phase 3: Verify ==="
ACTUAL=$(kubectl get "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.spec.replicas}')
READY=$(kubectl get "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}')
echo "Replicas: spec=$ACTUAL, ready=${READY:-0}"

if [ "$ACTUAL" = "$SCALE_TO" ]; then
  echo "=== SUCCESS: Deployment scaled from $CURRENT to $SCALE_TO replicas ==="
else
  echo "ERROR: Expected $SCALE_TO replicas but found $ACTUAL"
  exit 1
fi
