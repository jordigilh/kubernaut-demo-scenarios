#!/bin/sh
set -e

NS="$TARGET_RESOURCE_NAMESPACE"
KIND="$TARGET_RESOURCE_KIND"

echo "=== Phase 1: Resolve targets ==="
echo "TARGET_RESOURCE_KIND=$KIND  TARGET_RESOURCE_NAME=$TARGET_RESOURCE_NAME  NS=$NS"
echo "TARGET_CONFIGMAP_NAME=$TARGET_CONFIGMAP_NAME"

if [ "$KIND" = "ConfigMap" ]; then
  CM_NAME="$TARGET_RESOURCE_NAME"
  if [ -n "$TARGET_CONFIGMAP_NAME" ] && [ "$TARGET_CONFIGMAP_NAME" != "$CM_NAME" ]; then
    echo "WARN: TARGET_CONFIGMAP_NAME ($TARGET_CONFIGMAP_NAME) differs from TARGET_RESOURCE_NAME ($CM_NAME), using TARGET_RESOURCE_NAME"
  fi
  DEPLOY_NAME=$(kubectl get deployments -n "$NS" -o json | \
    jq -r --arg cm "$CM_NAME" '.items[] | select(.spec.template.spec.volumes[]?.configMap.name == $cm) | .metadata.name' | head -1)
  if [ -z "$DEPLOY_NAME" ]; then
    echo "ERROR: No Deployment found mounting ConfigMap $CM_NAME in namespace $NS"
    exit 1
  fi
  echo "Resolved: ConfigMap=$CM_NAME -> owning Deployment=$DEPLOY_NAME"
elif [ "$KIND" = "Deployment" ]; then
  DEPLOY_NAME="$TARGET_RESOURCE_NAME"
  CM_NAME="${TARGET_CONFIGMAP_NAME:-}"
  if [ -z "$CM_NAME" ]; then
    CM_NAME=$(kubectl get "deployment/$DEPLOY_NAME" -n "$NS" \
      -o jsonpath='{.spec.template.spec.volumes[0].configMap.name}')
    if [ -z "$CM_NAME" ]; then
      echo "ERROR: Deployment $DEPLOY_NAME has no ConfigMap volume and TARGET_CONFIGMAP_NAME was not provided"
      exit 1
    fi
    echo "Resolved: Deployment=$DEPLOY_NAME -> mounted ConfigMap=$CM_NAME"
  else
    echo "Targets: Deployment=$DEPLOY_NAME  ConfigMap=$CM_NAME"
  fi
else
  echo "ERROR: Unsupported TARGET_RESOURCE_KIND=$KIND (expected Deployment or ConfigMap)"
  exit 1
fi

echo "=== Phase 2: Validate ConfigMap ==="
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

echo "=== Phase 3: Action ==="
echo "Patching ConfigMap $CM_NAME to remove faulty configuration..."

FIXED_CONFIG=$(echo "$CONFIG_DATA" | grep -v "invalid_directive")

kubectl patch "configmap/$CM_NAME" -n "$NS" \
  --type=merge -p "{\"data\":{\"config.yaml\":$(echo "$FIXED_CONFIG" | jq -Rs .)}}"

echo "ConfigMap patched. Restarting deployment/$DEPLOY_NAME to pick up fixed config..."
kubectl rollout restart "deployment/$DEPLOY_NAME" -n "$NS"

echo "Waiting for rollout to complete..."
kubectl rollout status "deployment/$DEPLOY_NAME" -n "$NS" --timeout=120s

echo "=== Phase 4: Verify ==="
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
  echo "=== SUCCESS: ConfigMap $CM_NAME hotfixed in-place, deployment/$DEPLOY_NAME restarted, all replicas ready ==="
else
  echo "WARNING: Not all replicas ready after hotfix (${READY:-0}/$DESIRED)"
  exit 1
fi
