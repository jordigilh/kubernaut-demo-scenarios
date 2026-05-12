#!/bin/sh
set -e

echo "=== Phase 1: Validate ==="
echo "Checking Deployment ${TARGET_RESOURCE_NAME} in namespace ${TARGET_RESOURCE_NAMESPACE}..."

kubectl get deployment "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" >/dev/null 2>&1 || {
    echo "ERROR: Deployment ${TARGET_RESOURCE_NAME} not found"
    exit 1
}

AVAILABLE=$(kubectl get deployment "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
DESIRED=$(kubectl get deployment "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.spec.replicas}')
echo "Replicas: ${AVAILABLE:-0}/${DESIRED} available"

EVENTS=$(kubectl get events -n "$TARGET_RESOURCE_NAMESPACE" \
  --field-selector "reason=FailedCreate,involvedObject.name=$(kubectl get rs -n "$TARGET_RESOURCE_NAMESPACE" \
  -l app="$TARGET_RESOURCE_NAME" --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)" \
  -o jsonpath='{.items[0].message}' 2>/dev/null || echo "")
echo "Latest FailedCreate event: ${EVENTS:-none}"

CURRENT_SC=$(kubectl get deployment "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].securityContext}' 2>/dev/null || echo "{}")
echo "Current SecurityContext: ${CURRENT_SC}"

echo "Validated: Deployment has SCC-violating SecurityContext."

echo "=== Phase 2: Action ==="
echo "Reverting SecurityContext to restricted-v2 compliant configuration..."

kubectl patch deployment "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  --type=json -p='[
    {"op":"remove","path":"/spec/template/spec/containers/0/securityContext/runAsUser"},
    {"op":"remove","path":"/spec/template/spec/containers/0/securityContext/capabilities"},
    {"op":"replace","path":"/spec/template/spec/containers/0/securityContext/allowPrivilegeEscalation","value":false},
    {"op":"replace","path":"/spec/template/spec/containers/0/securityContext/runAsNonRoot","value":true}
  ]' 2>/dev/null || \
kubectl patch deployment "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  --type=merge -p '{"spec":{"template":{"spec":{"containers":[{"name":"app","securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"},"capabilities":{"drop":["ALL"]}}}]}}}}'

echo "=== Phase 3: Verify ==="
echo "Waiting for pods to schedule with compliant SecurityContext..."
TIMEOUT=120
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    AVAILABLE=$(kubectl get deployment "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
      -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    if [ "${AVAILABLE:-0}" -ge 1 ]; then
        echo "=== SUCCESS: Deployment ${TARGET_RESOURCE_NAME} recovered (${AVAILABLE}/${DESIRED} available) ==="
        exit 0
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

echo "WARNING: Deployment not fully recovered within ${TIMEOUT}s (${AVAILABLE:-0}/${DESIRED} available)"
exit 1
