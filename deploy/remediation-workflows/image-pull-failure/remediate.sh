#!/bin/sh
set -e

echo "=== Phase 1: Validate ==="
echo "Checking Deployment ${TARGET_RESOURCE_NAME} in namespace ${TARGET_RESOURCE_NAMESPACE}..."

kubectl get deployment "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" >/dev/null 2>&1 || {
    echo "ERROR: Deployment ${TARGET_RESOURCE_NAME} not found in ${TARGET_RESOURCE_NAMESPACE}"
    exit 1
}

IMAGE_PULL_SECRETS=$(kubectl get deployment "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}')
echo "ImagePullSecrets referenced: ${IMAGE_PULL_SECRETS:-none}"

SECRET_NAME=""
for s in $IMAGE_PULL_SECRETS; do
    if ! kubectl get secret "$s" -n "$TARGET_RESOURCE_NAMESPACE" >/dev/null 2>&1; then
        SECRET_NAME="$s"
        echo "Missing secret: ${SECRET_NAME}"
        break
    fi
done

if [ -z "$SECRET_NAME" ]; then
    SECRET_NAME=$(echo "$IMAGE_PULL_SECRETS" | tr ' ' '\n' | head -1)
    echo "No missing secrets detected. Will refresh: ${SECRET_NAME}"
fi

echo "Validated: will recreate secret '${SECRET_NAME}' from template."

echo "=== Phase 2: Action ==="

TEMPLATE_NS="kubernaut-workflows"
TEMPLATE_NAME="registry-credentials-template"

if kubectl get secret "$TEMPLATE_NAME" -n "$TEMPLATE_NS" >/dev/null 2>&1; then
    echo "Found credential template in ${TEMPLATE_NS}/${TEMPLATE_NAME}"
    DOCKER_CONFIG=$(kubectl get secret "$TEMPLATE_NAME" -n "$TEMPLATE_NS" \
      -o jsonpath='{.data.\.dockerconfigjson}')
else
    echo "No template found. Creating placeholder dockerconfigjson..."
    DOCKER_CONFIG=$(printf '{"auths":{}}' | base64)
fi

kubectl delete secret "$SECRET_NAME" -n "$TARGET_RESOURCE_NAMESPACE" --ignore-not-found

cat <<EOSECRET | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${TARGET_RESOURCE_NAMESPACE}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${DOCKER_CONFIG}
EOSECRET

echo "Secret '${SECRET_NAME}' recreated in ${TARGET_RESOURCE_NAMESPACE}."

echo "Restarting deployment to pick up new credentials..."
kubectl rollout restart deployment "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE"

echo "=== Phase 3: Verify ==="
echo "Waiting for rollout to complete..."
TIMEOUT=120
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    READY=$(kubectl get deployment "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get deployment "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
      -o jsonpath='{.spec.replicas}')
    if [ "${READY:-0}" = "$DESIRED" ] && [ -n "$DESIRED" ] && [ "$DESIRED" != "0" ]; then
        echo "=== SUCCESS: Deployment ${TARGET_RESOURCE_NAME} recovered (${READY}/${DESIRED} ready) ==="
        exit 0
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

echo "WARNING: Rollout not fully complete within ${TIMEOUT}s (${READY:-0}/${DESIRED} ready)"
exit 1
