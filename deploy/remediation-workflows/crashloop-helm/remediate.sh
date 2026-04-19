#!/bin/sh
set -e

: "${TARGET_RESOURCE_NAMESPACE:?TARGET_RESOURCE_NAMESPACE is required}"
: "${TARGET_RESOURCE_NAME:?TARGET_RESOURCE_NAME is required}"
: "${TARGET_RESOURCE_KIND:=Deployment}"

echo "=== Phase 0: Discover Helm release ==="

# Workaround for kubernaut#693: resolve ReplicaSet name -> Deployment name
KIND_LOWER=$(echo "${TARGET_RESOURCE_KIND}" | tr '[:upper:]' '[:lower:]')
if [ "${KIND_LOWER}" = "deployment" ] && \
   ! kubectl get "deployment/${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" >/dev/null 2>&1; then
  OWNER=$(kubectl get replicaset "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}' 2>/dev/null || true)
  if [ -n "$OWNER" ]; then
    echo "WARN: '${TARGET_RESOURCE_NAME}' is a ReplicaSet, resolved to Deployment '${OWNER}' (kubernaut#693)"
    TARGET_RESOURCE_NAME="$OWNER"
  fi
fi

echo "Target: ${TARGET_RESOURCE_KIND}/${TARGET_RESOURCE_NAME} in ${TARGET_RESOURCE_NAMESPACE}"

RELEASE_NAME=$(kubectl get "${KIND_LOWER}/${TARGET_RESOURCE_NAME}" \
  -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null || true)

if [ -z "${RELEASE_NAME}" ]; then
  echo "Label app.kubernetes.io/instance not found on ${TARGET_RESOURCE_KIND}/${TARGET_RESOURCE_NAME}."
  echo "Falling back to helm list..."
  RELEASES=$(helm list -n "${TARGET_RESOURCE_NAMESPACE}" -q 2>/dev/null)
  COUNT=$(echo "${RELEASES}" | grep -c . 2>/dev/null || echo "0")
  if [ "${COUNT}" -eq 1 ]; then
    RELEASE_NAME="${RELEASES}"
    echo "Single Helm release found: ${RELEASE_NAME}"
  elif [ "${COUNT}" -eq 0 ]; then
    echo "ERROR: No Helm releases found in namespace ${TARGET_RESOURCE_NAMESPACE}"
    exit 1
  else
    echo "ERROR: Multiple Helm releases in ${TARGET_RESOURCE_NAMESPACE}, cannot auto-select:"
    echo "${RELEASES}"
    exit 1
  fi
else
  echo "Discovered RELEASE_NAME=${RELEASE_NAME} from resource label"
fi

echo "=== Phase 1: Validate ==="
echo "Checking Helm release ${RELEASE_NAME} in ${TARGET_RESOURCE_NAMESPACE}..."

CURRENT_REV=$(helm history "${RELEASE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" --max 1 -o json | \
  jq -r '.[0].revision')
echo "Current Helm revision: ${CURRENT_REV}"

if [ "${CURRENT_REV}" -le 1 ]; then
  echo "ERROR: No previous revision to roll back to (current rev: ${CURRENT_REV})"
  exit 1
fi

RELEASE_STATUS=$(helm status "${RELEASE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" -o json | \
  jq -r '.info.status')
echo "Release status: ${RELEASE_STATUS}"

CRASH_PODS=$(kubectl get pods -n "${TARGET_RESOURCE_NAMESPACE}" \
  --field-selector=status.phase!=Running -o name 2>/dev/null | wc -l | tr -d ' ')
echo "Non-running pods: ${CRASH_PODS}"
echo "Validated: Helm release has rollback history."

echo "=== Phase 2: Action ==="
PREV_REV=$((CURRENT_REV - 1))
echo "Rolling back Helm release ${RELEASE_NAME} to revision ${PREV_REV}..."
helm rollback "${RELEASE_NAME}" "${PREV_REV}" -n "${TARGET_RESOURCE_NAMESPACE}" --wait --timeout 120s

echo "=== Phase 3: Verify ==="
NEW_REV=$(helm history "${RELEASE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" --max 1 -o json | \
  jq -r '.[0].revision')
echo "New Helm revision: ${NEW_REV}"

NEW_STATUS=$(helm status "${RELEASE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" -o json | \
  jq -r '.info.status')
echo "Release status: ${NEW_STATUS}"

DEPLOY_SELECTOR="app.kubernetes.io/instance=${RELEASE_NAME}"
DEPLOYS=$(kubectl get deployments -n "${TARGET_RESOURCE_NAMESPACE}" \
  -l "${DEPLOY_SELECTOR}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null)

if [ -n "${DEPLOYS}" ]; then
  echo "Checking Deployments with label ${DEPLOY_SELECTOR}:"
  echo "${DEPLOYS}" | while IFS='	' read -r NAME DESIRED READY; do
    READY=${READY:-0}
    echo "  ${NAME}: ${READY}/${DESIRED} ready"
  done
fi

if [ "${NEW_STATUS}" = "deployed" ]; then
  echo "=== SUCCESS: Helm release rolled back (rev ${CURRENT_REV} -> ${NEW_REV}), status=deployed ==="
else
  echo "ERROR: Rollback may not have fully succeeded (status=${NEW_STATUS})"
  exit 1
fi
