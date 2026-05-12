#!/bin/sh
set -e

# Increase Database Connections workflow: patches a ConfigMap to raise
# POSTGRESQL_MAX_CONNECTIONS, then restarts the owning Deployment so
# PostgreSQL picks up the new limit.
#
# Environment variables (injected by WFE controller):
#   TARGET_RESOURCE_NAMESPACE - namespace of the target
#   TARGET_RESOURCE_NAME      - name of the Deployment or ConfigMap
#   TARGET_RESOURCE_KIND      - Deployment or ConfigMap
#   TARGET_CONFIGMAP_NAME     - (optional) ConfigMap holding connection settings

NS="$TARGET_RESOURCE_NAMESPACE"
KIND="$TARGET_RESOURCE_KIND"
NEW_MAX="${NEW_MAX_CONNECTIONS:-50}"

echo "=== Phase 1: Resolve targets ==="
echo "TARGET_RESOURCE_KIND=$KIND  TARGET_RESOURCE_NAME=$TARGET_RESOURCE_NAME  NS=$NS"

if [ "$KIND" = "ConfigMap" ]; then
  CM_NAME="$TARGET_RESOURCE_NAME"
  DEPLOY_NAME=$(kubectl get deployments -n "$NS" -o json | \
    jq -r --arg cm "$CM_NAME" \
    '.items[] | select(.spec.template.spec.containers[].envFrom[]?.configMapRef.name == $cm) | .metadata.name' \
    | head -1)
  if [ -z "$DEPLOY_NAME" ]; then
    echo "ERROR: No Deployment found using envFrom ConfigMap $CM_NAME in namespace $NS"
    exit 1
  fi
  echo "Resolved: ConfigMap=$CM_NAME -> owning Deployment=$DEPLOY_NAME"
elif [ "$KIND" = "Deployment" ]; then
  DEPLOY_NAME="$TARGET_RESOURCE_NAME"
  CM_NAME="${TARGET_CONFIGMAP_NAME:-}"
  if [ -z "$CM_NAME" ]; then
    CM_NAME=$(kubectl get "deployment/$DEPLOY_NAME" -n "$NS" \
      -o jsonpath='{.spec.template.spec.containers[0].envFrom[0].configMapRef.name}' 2>/dev/null || true)
    if [ -z "$CM_NAME" ]; then
      echo "ERROR: Deployment $DEPLOY_NAME has no envFrom ConfigMap and TARGET_CONFIGMAP_NAME was not provided"
      exit 1
    fi
    echo "Resolved: Deployment=$DEPLOY_NAME -> envFrom ConfigMap=$CM_NAME"
  else
    echo "Targets: Deployment=$DEPLOY_NAME  ConfigMap=$CM_NAME"
  fi
else
  echo "ERROR: Unsupported TARGET_RESOURCE_KIND=$KIND (expected Deployment or ConfigMap)"
  exit 1
fi

echo "=== Phase 2: Validate current settings ==="
CURRENT_MAX=$(kubectl get "configmap/$CM_NAME" -n "$NS" \
  -o jsonpath='{.data.POSTGRESQL_MAX_CONNECTIONS}' 2>/dev/null || echo "")

if [ -z "$CURRENT_MAX" ]; then
  echo "ERROR: ConfigMap $CM_NAME has no POSTGRESQL_MAX_CONNECTIONS key"
  exit 1
fi

echo "Current POSTGRESQL_MAX_CONNECTIONS: $CURRENT_MAX"
echo "Target  POSTGRESQL_MAX_CONNECTIONS: $NEW_MAX"

if [ "$CURRENT_MAX" -ge "$NEW_MAX" ] 2>/dev/null; then
  echo "Current limit ($CURRENT_MAX) is already >= target ($NEW_MAX). Nothing to do."
  exit 0
fi

echo "=== Phase 3: Patch ConfigMap ==="
kubectl patch "configmap/$CM_NAME" -n "$NS" \
  --type=merge -p "{\"data\":{\"POSTGRESQL_MAX_CONNECTIONS\":\"$NEW_MAX\"}}"
echo "ConfigMap patched. Restarting deployment/$DEPLOY_NAME to pick up new limit..."

kubectl rollout restart "deployment/$DEPLOY_NAME" -n "$NS"
echo "Waiting for rollout to complete..."
kubectl rollout status "deployment/$DEPLOY_NAME" -n "$NS" --timeout=120s

echo "=== Phase 4: Verify ==="
UPDATED_MAX=$(kubectl get "configmap/$CM_NAME" -n "$NS" \
  -o jsonpath='{.data.POSTGRESQL_MAX_CONNECTIONS}')
READY=$(kubectl get "deployment/$DEPLOY_NAME" -n "$NS" \
  -o jsonpath='{.status.readyReplicas}')
DESIRED=$(kubectl get "deployment/$DEPLOY_NAME" -n "$NS" \
  -o jsonpath='{.spec.replicas}')
echo "POSTGRESQL_MAX_CONNECTIONS: $UPDATED_MAX (was: $CURRENT_MAX)"
echo "Replicas: ${READY:-0}/$DESIRED ready"

if [ "$UPDATED_MAX" = "$NEW_MAX" ] && [ "${READY:-0}" = "$DESIRED" ] && [ -n "$DESIRED" ]; then
  echo "=== SUCCESS: max_connections increased from $CURRENT_MAX to $NEW_MAX, deployment/$DEPLOY_NAME restarted ==="
else
  echo "ERROR: Verification failed"
  exit 1
fi
