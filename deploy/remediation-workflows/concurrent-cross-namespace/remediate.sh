#!/bin/sh
set -e

NS="$TARGET_RESOURCE_NAMESPACE"
CM_NAME="$TARGET_RESOURCE_NAME"

echo "=== Phase 1: Validate ==="

if [ "$TARGET_RESOURCE_KIND" = "Deployment" ]; then
  echo "Target is a Deployment ($CM_NAME). Resolving mounted ConfigMap..."
  DEPLOY_NAME="$CM_NAME"
  CM_NAME=$(kubectl get "deployment/$DEPLOY_NAME" -n "$NS" \
    -o jsonpath='{.spec.template.spec.volumes[0].configMap.name}')
  if [ -z "$CM_NAME" ]; then
    echo "ERROR: No ConfigMap volume found on deployment/$DEPLOY_NAME"
    exit 1
  fi
  echo "Resolved ConfigMap: $CM_NAME"
else
  echo "Target is ConfigMap/$CM_NAME in namespace $NS"
  echo "Looking up Deployment that mounts this ConfigMap..."
  DEPLOY_NAME=$(kubectl get deployments -n "$NS" -o json | \
    jq -r --arg cm "$CM_NAME" \
      '.items[] | select(.spec.template.spec.volumes[]? | .configMap?.name == $cm) | .metadata.name' \
    | head -1) || true
  if [ -z "$DEPLOY_NAME" ]; then
    echo "ERROR: No Deployment found mounting ConfigMap/$CM_NAME in namespace $NS"
    exit 1
  fi
  echo "Found Deployment: $DEPLOY_NAME"
fi

CONFIG_DATA=$(kubectl get "configmap/$CM_NAME" -n "$NS" \
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

kubectl patch "configmap/$CM_NAME" -n "$NS" \
  --type=merge -p "{\"data\":{\"config.yaml\":$(echo "$FIXED_CONFIG" | jq -Rs .)}}"

echo "ConfigMap patched. Restarting deployment/$DEPLOY_NAME to pick up fixed config..."
kubectl rollout restart "deployment/$DEPLOY_NAME" -n "$NS"

echo "Waiting for rollout to complete..."
kubectl rollout status "deployment/$DEPLOY_NAME" -n "$NS" --timeout=120s

echo "=== Phase 3: Verify ==="
NEW_CONFIG=$(kubectl get "configmap/$CM_NAME" -n "$NS" \
  -o jsonpath='{.data.config\.yaml}')

if echo "$NEW_CONFIG" | grep -q "invalid_directive"; then
  echo "ERROR: invalid_directive still present in ConfigMap after patch"
  exit 1
fi

READY=$(kubectl get "deployment/$DEPLOY_NAME" -n "$NS" \
  -o jsonpath='{.status.readyReplicas}')
DESIRED=$(kubectl get "deployment/$DEPLOY_NAME" -n "$NS" \
  -o jsonpath='{.spec.replicas}')
echo "Replicas: ${READY:-0}/$DESIRED ready"

if [ "${READY:-0}" = "$DESIRED" ] && [ -n "$DESIRED" ]; then
  echo "=== SUCCESS: ConfigMap hotfixed in-place ($CM_NAME), deployment/$DEPLOY_NAME restarted, all replicas ready ==="
else
  echo "WARNING: Not all replicas ready after hotfix (${READY:-0}/$DESIRED)"
  exit 1
fi
