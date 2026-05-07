#!/bin/sh
set -e

echo "=== Phase 1: Validate ==="
echo "Checking BuildConfig ${TARGET_RESOURCE_NAME} in namespace ${TARGET_RESOURCE_NAMESPACE}..."

BC_JSON=$(kubectl get buildconfig "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" -o json 2>/dev/null) || {
    echo "ERROR: BuildConfig ${TARGET_RESOURCE_NAME} not found in ${TARGET_RESOURCE_NAMESPACE}"
    exit 1
}

CURRENT_URI=$(echo "$BC_JSON" | grep -o '"uri" *: *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"//')
CURRENT_REF=$(echo "$BC_JSON" | grep -o '"ref" *: *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"//')
echo "Current Git URI: ${CURRENT_URI}"
echo "Current Git ref: ${CURRENT_REF:-<default branch>}"

FAILED_BUILDS=$(kubectl get builds -n "$TARGET_RESOURCE_NAMESPACE" \
  -l "buildconfig=${TARGET_RESOURCE_NAME}" \
  -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
  | grep -c "Failed" || echo "0")
echo "Failed builds: ${FAILED_BUILDS}"

LAST_BUILD_LOG=$(kubectl get builds -n "$TARGET_RESOURCE_NAMESPACE" \
  -l "buildconfig=${TARGET_RESOURCE_NAME}" \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
if [ -n "$LAST_BUILD_LOG" ]; then
    echo "Last build: ${LAST_BUILD_LOG}"
    kubectl logs "build/${LAST_BUILD_LOG}" -n "$TARGET_RESOURCE_NAMESPACE" --tail=5 2>/dev/null || true
fi

GOOD_URI=$(kubectl get configmap build-source-config -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.data.git-uri}' 2>/dev/null || echo "")
GOOD_REF=$(kubectl get configmap build-source-config -n "$TARGET_RESOURCE_NAMESPACE" \
  -o jsonpath='{.data.git-ref}' 2>/dev/null || echo "main")

if [ -z "$GOOD_URI" ]; then
    echo "ERROR: No known-good source config found (ConfigMap build-source-config missing)"
    exit 1
fi

echo "Known-good Git URI: ${GOOD_URI}"
echo "Known-good Git ref: ${GOOD_REF}"
echo "Validated: will restore BuildConfig source reference."

echo "=== Phase 2: Action ==="
echo "Patching BuildConfig ${TARGET_RESOURCE_NAME} source to known-good values..."

kubectl patch buildconfig "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
  --type=merge -p "{\"spec\":{\"source\":{\"git\":{\"uri\":\"${GOOD_URI}\",\"ref\":\"${GOOD_REF}\"}}}}"

echo "Triggering new build via BuildConfig instantiate API..."
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
API_URL="https://kubernetes.default.svc/apis/build.openshift.io/v1/namespaces/${TARGET_RESOURCE_NAMESPACE}/buildconfigs/${TARGET_RESOURCE_NAME}/instantiate"
HTTP_CODE=$(curl -s -o /tmp/build-response.json -w "%{http_code}" -X POST -k "$API_URL" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"kind\":\"BuildRequest\",\"apiVersion\":\"build.openshift.io/v1\",\"metadata\":{\"name\":\"${TARGET_RESOURCE_NAME}\"}}")
if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    BUILD_NAME=$(grep -o '"name":"[^"]*"' /tmp/build-response.json | head -1 | cut -d'"' -f4)
    echo "Build ${BUILD_NAME} triggered (HTTP ${HTTP_CODE})"
else
    echo "ERROR: Failed to trigger build (HTTP ${HTTP_CODE})"
    cat /tmp/build-response.json 2>/dev/null
    exit 1
fi

echo "=== Phase 3: Verify ==="
echo "Waiting for new build to start..."
TIMEOUT=180
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    LATEST=$(kubectl get builds -n "$TARGET_RESOURCE_NAMESPACE" \
      -l "buildconfig=${TARGET_RESOURCE_NAME}" \
      --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].status.phase}' 2>/dev/null || echo "")
    case "$LATEST" in
        Complete)
            echo "=== SUCCESS: Build completed. BuildConfig source restored to ${GOOD_URI}@${GOOD_REF} ==="
            exit 0
            ;;
        Failed|Error|Cancelled)
            echo "ERROR: New build ended with phase: ${LATEST}"
            exit 1
            ;;
        *)
            echo "  Build phase: ${LATEST:-Pending}..."
            ;;
    esac
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

echo "WARNING: Build still in progress after ${TIMEOUT}s"
exit 1
