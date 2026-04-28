#!/bin/sh
set -e

: "${TARGET_RESOURCE_NAME:?TARGET_RESOURCE_NAME is required}"

# When the RCA targets a PVC (e.g. data-kv-store-2), derive the owning
# StatefulSet name. PVC naming convention: <vct>-<sts>-<ordinal>.
if [ "${TARGET_RESOURCE_KIND:-}" = "PersistentVolumeClaim" ]; then
  echo "RCA target is PVC '${TARGET_RESOURCE_NAME}'. Resolving owning StatefulSet..."
  TARGET_PVC="${TARGET_RESOURCE_NAME}"
  STS_NAME=$(kubectl get statefulset -n "${TARGET_RESOURCE_NAMESPACE:-}" -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r sts; do
        echo "${TARGET_RESOURCE_NAME}" | grep -q ".*-${sts}-[0-9]*$" && echo "$sts" && break
      done)
  if [ -n "${STS_NAME}" ]; then
    echo "Resolved StatefulSet: ${STS_NAME}"
    TARGET_RESOURCE_NAME="${STS_NAME}"
  else
    echo "WARNING: Could not derive StatefulSet from PVC name '${TARGET_PVC}'. Trying as-is."
  fi
fi

if [ -z "${TARGET_RESOURCE_NAMESPACE:-}" ]; then
  echo "TARGET_RESOURCE_NAMESPACE not set. Discovering namespace for StatefulSet ${TARGET_RESOURCE_NAME}..."
  TARGET_RESOURCE_NAMESPACE=$(kubectl get statefulset -A -o jsonpath="{range .items[?(@.metadata.name==\"${TARGET_RESOURCE_NAME}\")]}{.metadata.namespace}{end}" 2>/dev/null || echo "")
  if [ -z "${TARGET_RESOURCE_NAMESPACE}" ]; then
    echo "ERROR: Cannot discover namespace for StatefulSet '${TARGET_RESOURCE_NAME}'"
    exit 1
  fi
  echo "Discovered namespace: ${TARGET_RESOURCE_NAMESPACE}"
fi

echo "=== Phase 1: Validate ==="
echo "Checking StatefulSet ${TARGET_RESOURCE_NAME} in ${TARGET_RESOURCE_NAMESPACE}..."

READY=$(kubectl get statefulset "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
DESIRED=$(kubectl get statefulset "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.spec.replicas}')
echo "Replicas: ${READY}/${DESIRED} ready"

if [ "${READY}" = "${DESIRED}" ]; then
  echo "All replicas are ready. No action needed."
  exit 0
fi

STORAGE_CLASS=$(kubectl get statefulset "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.spec.volumeClaimTemplates[0].spec.storageClassName}' 2>/dev/null || echo "")
STORAGE_SIZE=$(kubectl get statefulset "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}')
VCT_NAME=$(kubectl get statefulset "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}')
echo "VolumeClaimTemplate: name=${VCT_NAME}, size=${STORAGE_SIZE}, storageClass=${STORAGE_CLASS:-default}"

PENDING_PODS=$(kubectl get pods -n "${TARGET_RESOURCE_NAMESPACE}" -l "app=${TARGET_RESOURCE_NAME}" \
  --field-selector=status.phase=Pending -o name 2>/dev/null || echo "")

if [ -z "${PENDING_PODS}" ]; then
  echo "No Pending pods found. Issue may be different than expected."
  PENDING_PODS=$(kubectl get pods -n "${TARGET_RESOURCE_NAMESPACE}" -l "app=${TARGET_RESOURCE_NAME}" \
    --field-selector=status.phase!=Running -o name 2>/dev/null || echo "none")
fi
echo "Stuck pods: ${PENDING_PODS}"

if [ -n "${TARGET_PVC:-}" ]; then
  MISSING_PVC="${TARGET_PVC}"
else
  MISSING_PVC=""
  for i in $(seq 0 $((DESIRED - 1))); do
    PVC_NAME="${VCT_NAME}-${TARGET_RESOURCE_NAME}-${i}"
    if ! kubectl get pvc "${PVC_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" >/dev/null 2>&1; then
      MISSING_PVC="${PVC_NAME}"
      break
    fi
  done
fi

if [ -z "${MISSING_PVC:-}" ]; then
  echo "ERROR: Could not identify missing PVC"
  exit 1
fi
echo "Missing PVC: ${MISSING_PVC}"
echo "Validated: StatefulSet has missing PVC causing stuck pod."

echo "=== Phase 2: Action ==="

POD_INDEX=$(echo "${MISSING_PVC}" | grep -o '[0-9]*$')
STUCK_POD="${TARGET_RESOURCE_NAME}-${POD_INDEX}"

EXISTING_PHASE=$(kubectl get pvc "${MISSING_PVC}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

if [ -n "${EXISTING_PHASE}" ] && [ "${EXISTING_PHASE}" = "Bound" ]; then
  echo "PVC ${MISSING_PVC} already exists and is Bound (auto-healed by StatefulSet controller)."
  echo "Deleting stuck pod to trigger reschedule..."
  kubectl delete pod "${STUCK_POD}" -n "${TARGET_RESOURCE_NAMESPACE}" --ignore-not-found --grace-period=0
elif [ -n "${EXISTING_PHASE}" ]; then
  echo "PVC ${MISSING_PVC} exists but is ${EXISTING_PHASE} (not Bound)."
  echo "Deleting stuck pod ${STUCK_POD} to release PVC protection finalizer..."
  kubectl delete pod "${STUCK_POD}" -n "${TARGET_RESOURCE_NAMESPACE}" --ignore-not-found --grace-period=0
  sleep 3
  echo "Deleting broken PVC ${MISSING_PVC}..."
  kubectl delete pvc "${MISSING_PVC}" -n "${TARGET_RESOURCE_NAMESPACE}" --wait=true --timeout=15s 2>/dev/null || true
  sleep 2

  RECHECK_PHASE=$(kubectl get pvc "${MISSING_PVC}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "${RECHECK_PHASE}" = "Bound" ]; then
    echo "PVC was auto-recreated and bound by StatefulSet controller."
  elif [ -z "${RECHECK_PHASE}" ]; then
    echo "PVC deleted. Recreating ${MISSING_PVC}..."
    PVC_YAML="/tmp/pvc-${MISSING_PVC}.yaml"
    cat > "${PVC_YAML}" <<PVCEOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${MISSING_PVC}
  namespace: ${TARGET_RESOURCE_NAMESPACE}
  labels:
    app: ${TARGET_RESOURCE_NAME}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ${STORAGE_SIZE}
PVCEOF
    if [ -n "${STORAGE_CLASS}" ]; then
      echo "  storageClassName: ${STORAGE_CLASS}" >> "${PVC_YAML}"
    fi
    kubectl apply -f "${PVC_YAML}"
    rm -f "${PVC_YAML}"
  else
    echo "WARNING: PVC still in ${RECHECK_PHASE} state after delete attempt."
  fi
else
  echo "PVC ${MISSING_PVC} does not exist. Creating..."
  PVC_YAML="/tmp/pvc-${MISSING_PVC}.yaml"
  cat > "${PVC_YAML}" <<PVCEOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${MISSING_PVC}
  namespace: ${TARGET_RESOURCE_NAMESPACE}
  labels:
    app: ${TARGET_RESOURCE_NAME}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: ${STORAGE_SIZE}
PVCEOF
  if [ -n "${STORAGE_CLASS}" ]; then
    echo "  storageClassName: ${STORAGE_CLASS}" >> "${PVC_YAML}"
  fi
  kubectl apply -f "${PVC_YAML}"
  rm -f "${PVC_YAML}"
  echo "Deleting stuck pod to trigger reschedule..."
  kubectl delete pod "${STUCK_POD}" -n "${TARGET_RESOURCE_NAMESPACE}" --ignore-not-found --grace-period=0
fi

echo "Waiting for StatefulSet to reconcile (30s)..."
sleep 30

echo "=== Phase 3: Verify ==="
NEW_READY=$(kubectl get statefulset "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
echo "Replicas: ${NEW_READY}/${DESIRED} ready"

PVC_STATUS=$(kubectl get pvc "${MISSING_PVC}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
echo "PVC ${MISSING_PVC} status: ${PVC_STATUS}"

if [ "${NEW_READY}" = "${DESIRED}" ]; then
  echo "=== SUCCESS: PVC fixed, all ${DESIRED} StatefulSet replicas ready ==="
else
  echo "WARNING: Not all replicas ready yet (${NEW_READY}/${DESIRED}). May need more time."
  exit 1
fi
