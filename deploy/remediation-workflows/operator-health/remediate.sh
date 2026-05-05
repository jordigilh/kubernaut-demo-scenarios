#!/bin/sh
set -e

echo "=== Phase 1: Validate ==="
echo "Checking Subscription ${TARGET_RESOURCE_NAME} in namespace ${TARGET_RESOURCE_NAMESPACE}..."

SUB_JSON=$(kubectl get subscription "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" -o json 2>/dev/null) || {
    echo "ERROR: Subscription ${TARGET_RESOURCE_NAME} not found in ${TARGET_RESOURCE_NAMESPACE}"
    exit 1
}

PACKAGE=$(echo "$SUB_JSON" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
CHANNEL=$(echo "$SUB_JSON" | grep -o '"channel":"[^"]*"' | head -1 | cut -d'"' -f4)
SOURCE=$(echo "$SUB_JSON" | grep -o '"source":"[^"]*"' | head -1 | cut -d'"' -f4)
SOURCE_NS=$(echo "$SUB_JSON" | grep -o '"sourceNamespace":"[^"]*"' | head -1 | cut -d'"' -f4)
INSTALL_MODE=$(echo "$SUB_JSON" | grep -o '"installPlanApproval":"[^"]*"' | head -1 | cut -d'"' -f4)

echo "Package: ${PACKAGE}"
echo "Channel: ${CHANNEL}"
echo "CatalogSource: ${SOURCE} (${SOURCE_NS})"
echo "InstallPlanApproval: ${INSTALL_MODE:-Automatic}"

CSV_NAME=$(echo "$SUB_JSON" | grep -o '"currentCSV":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
echo "Current CSV reference: ${CSV_NAME:-<none>}"

if [ -n "$CSV_NAME" ]; then
    CSV_PHASE=$(kubectl get csv "$CSV_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")
    echo "CSV phase: ${CSV_PHASE}"
else
    echo "CSV is missing from Subscription status."
fi

echo "Validated: operator needs restoration."

echo "=== Phase 2: Action ==="

echo "Deleting current Subscription to reset OLM state..."
kubectl delete subscription "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" --wait=true

if [ -n "$CSV_NAME" ]; then
    echo "Cleaning up old CSV ${CSV_NAME}..."
    kubectl delete csv "$CSV_NAME" -n "$TARGET_RESOURCE_NAMESPACE" --ignore-not-found --wait=true
fi

echo "Recreating Subscription..."
cat <<EOSUB | kubectl apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${TARGET_RESOURCE_NAME}
  namespace: ${TARGET_RESOURCE_NAMESPACE}
spec:
  channel: ${CHANNEL}
  name: ${PACKAGE}
  source: ${SOURCE}
  sourceNamespace: ${SOURCE_NS:-openshift-marketplace}
  installPlanApproval: ${INSTALL_MODE:-Automatic}
EOSUB

echo "=== Phase 3: Verify ==="
echo "Waiting for OLM to install operator CSV..."
TIMEOUT=300
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    NEW_CSV=$(kubectl get subscription "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
      -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    if [ -n "$NEW_CSV" ]; then
        PHASE=$(kubectl get csv "$NEW_CSV" -n "$TARGET_RESOURCE_NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$PHASE" = "Succeeded" ]; then
            echo "=== SUCCESS: Operator restored. CSV ${NEW_CSV} phase: Succeeded ==="
            exit 0
        fi
        echo "  CSV ${NEW_CSV} phase: ${PHASE:-Pending}..."
    else
        IP_COUNT=$(kubectl get installplan -n "$TARGET_RESOURCE_NAMESPACE" \
          -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
        echo "  Waiting for CSV... (${IP_COUNT} InstallPlans)"
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

echo "WARNING: CSV not fully installed within ${TIMEOUT}s"
exit 1
