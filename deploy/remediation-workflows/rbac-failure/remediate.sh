#!/bin/sh
set -e

echo "=== Phase 1: Validate ==="
echo "Checking RoleBinding ${TARGET_RESOURCE_NAME} in namespace ${TARGET_RESOURCE_NAMESPACE}..."

if kubectl get rolebinding "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" >/dev/null 2>&1; then
    echo "RoleBinding ${TARGET_RESOURCE_NAME} already exists. Checking if it's correct..."
    ROLE_REF=$(kubectl get rolebinding "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
      -o jsonpath='{.roleRef.name}')
    echo "References role: ${ROLE_REF}"
else
    echo "RoleBinding ${TARGET_RESOURCE_NAME} is MISSING."
fi

TEMPLATE_NS="kubernaut-workflows"
TEMPLATE_NAME="rolebinding-template-${TARGET_RESOURCE_NAME}"

TEMPLATE_JSON=$(kubectl get configmap "$TEMPLATE_NAME" -n "$TEMPLATE_NS" \
  -o jsonpath='{.data.rolebinding\.yaml}' 2>/dev/null || echo "")

if [ -z "$TEMPLATE_JSON" ]; then
    echo "No template ConfigMap found. Discovering from namespace resources..."

    ROLE_NAME=$(kubectl get roles -n "$TARGET_RESOURCE_NAMESPACE" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)

    if [ -z "$ROLE_NAME" ]; then
        echo "ERROR: No Roles found in namespace ${TARGET_RESOURCE_NAMESPACE}"
        exit 1
    fi

    SA_NAME=""
    # Prefer SA matching the target resource name (e.g. metrics-collector)
    if kubectl get serviceaccount "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" >/dev/null 2>&1; then
        SA_NAME="$TARGET_RESOURCE_NAME"
    fi
    # Fallback: first SA excluding default and OCP built-in SAs
    if [ -z "$SA_NAME" ]; then
        SA_NAME=$(kubectl get serviceaccounts -n "$TARGET_RESOURCE_NAMESPACE" \
          -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
          | grep -v -E '^(default|builder|deployer|pipeline)$' | head -1)
    fi
    if [ -z "$SA_NAME" ]; then
        SA_NAME="default"
    fi

    echo "Discovered Role: ${ROLE_NAME}, ServiceAccount: ${SA_NAME}"
    echo "Validated: will recreate RoleBinding."

    echo "=== Phase 2: Action ==="
    echo "Creating RoleBinding ${TARGET_RESOURCE_NAME}..."

    cat <<EORB | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${TARGET_RESOURCE_NAME}
  namespace: ${TARGET_RESOURCE_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${ROLE_NAME}
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${TARGET_RESOURCE_NAMESPACE}
EORB
else
    echo "Using template from ${TEMPLATE_NS}/${TEMPLATE_NAME}..."
    echo "Validated: will apply template."

    echo "=== Phase 2: Action ==="
    echo "Applying RoleBinding template..."
    echo "$TEMPLATE_JSON" | sed "s/NAMESPACE_PLACEHOLDER/${TARGET_RESOURCE_NAMESPACE}/g" | kubectl apply -f -
fi

echo "Restarting affected Deployment to pick up restored RBAC..."
DEPLOYMENTS=$(kubectl get deployments -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

for deploy in $DEPLOYMENTS; do
    AVAILABLE=$(kubectl get deployment "$deploy" -n "$TARGET_RESOURCE_NAMESPACE" \
      -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    if [ "${AVAILABLE:-0}" = "0" ]; then
        echo "  Restarting unhealthy deployment: ${deploy}"
        kubectl rollout restart deployment "$deploy" -n "$TARGET_RESOURCE_NAMESPACE"
    fi
done

echo "=== Phase 3: Verify ==="
echo "Waiting for deployments to recover..."
TIMEOUT=120
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    ALL_HEALTHY=true
    for deploy in $DEPLOYMENTS; do
        AVAILABLE=$(kubectl get deployment "$deploy" -n "$TARGET_RESOURCE_NAMESPACE" \
          -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
        DESIRED=$(kubectl get deployment "$deploy" -n "$TARGET_RESOURCE_NAMESPACE" \
          -o jsonpath='{.spec.replicas}')
        if [ "${AVAILABLE:-0}" != "$DESIRED" ]; then
            ALL_HEALTHY=false
        fi
    done
    if [ "$ALL_HEALTHY" = "true" ]; then
        echo "=== SUCCESS: RoleBinding ${TARGET_RESOURCE_NAME} restored, all deployments healthy ==="
        exit 0
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

echo "WARNING: Not all deployments recovered within ${TIMEOUT}s"
exit 1
