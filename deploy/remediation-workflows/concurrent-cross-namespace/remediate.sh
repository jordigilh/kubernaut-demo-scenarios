#!/bin/sh
set -e

# Workaround for kubernaut#693: resolve ReplicaSet name -> Deployment name
if ! kubectl get "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" >/dev/null 2>&1; then
  OWNER=$(kubectl get replicaset "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE"     -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}' 2>/dev/null || true)
  if [ -n "$OWNER" ]; then
    echo "WARN: '$TARGET_RESOURCE_NAME' is a ReplicaSet, resolved to Deployment '$OWNER' (kubernaut#693)"
    TARGET_RESOURCE_NAME="$OWNER"
  fi
fi

echo "=== Phase 1: Validate ==="
echo "Checking deployment/$TARGET_RESOURCE_NAME in namespace $TARGET_RESOURCE_NAMESPACE..."

CM_NAME=$(kubectl get "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.volumes[0].configMap.name}')
echo "Mounted ConfigMap: $CM_NAME"

if [ -z "$CM_NAME" ]; then
  echo "ERROR: No ConfigMap volume found on deployment/$TARGET_RESOURCE_NAME"
  exit 1
fi

CONFIG_DATA=$(kubectl get "configmap/$CM_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.data.config\.yaml}')

if [ -z "$CONFIG_DATA" ]; then
  echo "ERROR: ConfigMap $CM_NAME has no 'config.yaml' key"
  exit 1
fi

if ! echo "$CONFIG_DATA" | grep -q "invalid_directive"; then
  echo "ERROR: No 'invalid_directive' found in ConfigMap $CM_NAME -- nothing to hotfix"
  exit 1
fi

echo "Found invalid_directive in ConfigMap $CM_NAME -- will patch in-place."

echo "=== Phase 2: Action ==="
echo "Patching ConfigMap $CM_NAME to remove faulty configuration..."

FIXED_CONFIG=$(echo "$CONFIG_DATA" | grep -v "invalid_directive")

kubectl patch "configmap/$CM_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  --type=merge -p "{\"data\":{\"config.yaml\":$(echo "$FIXED_CONFIG" | jq -Rs .)}}"

echo "ConfigMap patched. Restarting deployment to pick up fixed config..."
kubectl rollout restart "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE"

echo "Waiting for rollout to complete..."
kubectl rollout status "deployment/$TARGET_RESOURCE_NAME" \
  -n "$TARGET_RESOURCE_NAMESPACE" --timeout=120s

echo "=== Phase 3: Verify ==="
NEW_CONFIG=$(kubectl get "configmap/$CM_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.data.config\.yaml}')

if echo "$NEW_CONFIG" | grep -q "invalid_directive"; then
  echo "ERROR: invalid_directive still present in ConfigMap after patch"
  exit 1
fi

READY=$(kubectl get "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}')
DESIRED=$(kubectl get "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.spec.replicas}')
echo "Replicas: ${READY:-0}/$DESIRED ready"

if [ "${READY:-0}" = "$DESIRED" ] && [ -n "$DESIRED" ]; then
  echo "=== SUCCESS: ConfigMap hotfixed in-place ($CM_NAME), deployment restarted, all replicas ready ==="
else
  echo "WARNING: Not all replicas ready after hotfix (${READY:-0}/$DESIRED)"
  exit 1
fi
