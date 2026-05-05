#!/bin/sh
set -e

echo "=== Phase 1: Validate ==="
echo "Checking Route ${TARGET_RESOURCE_NAME} in namespace ${TARGET_RESOURCE_NAMESPACE}..."

ROUTE_JSON=$(kubectl get route "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" -o json 2>/dev/null) || {
    echo "ERROR: Route ${TARGET_RESOURCE_NAME} not found in ${TARGET_RESOURCE_NAMESPACE}"
    exit 1
}

CURRENT_TARGET=$(echo "$ROUTE_JSON" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "Current Route target service: ${CURRENT_TARGET}"

if kubectl get service "$CURRENT_TARGET" -n "$TARGET_RESOURCE_NAMESPACE" >/dev/null 2>&1; then
    ENDPOINTS=$(kubectl get endpoints "$CURRENT_TARGET" -n "$TARGET_RESOURCE_NAMESPACE" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
    if [ -n "$ENDPOINTS" ]; then
        echo "Service ${CURRENT_TARGET} exists and has endpoints. Route target may be correct."
        echo "Checking for other issues..."
    else
        echo "Service ${CURRENT_TARGET} exists but has NO endpoints."
    fi
else
    echo "Service ${CURRENT_TARGET} does NOT exist."
fi

SERVICES=$(kubectl get services -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v "^$" || echo "")
echo "Available services in namespace: ${SERVICES}"

CORRECT_SVC=""
for svc in $SERVICES; do
    if [ "$svc" = "$CURRENT_TARGET" ]; then
        continue
    fi
    EP=$(kubectl get endpoints "$svc" -n "$TARGET_RESOURCE_NAMESPACE" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
    if [ -n "$EP" ]; then
        CORRECT_SVC="$svc"
        echo "Found service with healthy endpoints: ${CORRECT_SVC}"
        break
    fi
done

if [ -z "$CORRECT_SVC" ]; then
    echo "ERROR: Could not determine correct target service"
    exit 1
fi

echo "Validated: will patch Route to target service '${CORRECT_SVC}'."

echo "=== Phase 2: Action ==="
echo "Patching Route ${TARGET_RESOURCE_NAME} to target service ${CORRECT_SVC}..."

kubectl patch route "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  --type=merge -p "{\"spec\":{\"to\":{\"name\":\"${CORRECT_SVC}\"}}}"

echo "=== Phase 3: Verify ==="
echo "Verifying Route target updated..."
sleep 5

NEW_TARGET=$(kubectl get route "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.spec.to.name}')

if [ "$NEW_TARGET" = "$CORRECT_SVC" ]; then
    echo "=== SUCCESS: Route ${TARGET_RESOURCE_NAME} target updated from '${CURRENT_TARGET}' to '${CORRECT_SVC}' ==="
else
    echo "ERROR: Route target is '${NEW_TARGET}', expected '${CORRECT_SVC}'"
    exit 1
fi
