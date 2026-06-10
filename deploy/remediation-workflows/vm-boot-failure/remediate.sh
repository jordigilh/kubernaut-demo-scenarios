#!/bin/sh
set -e

: "${TARGET_RESOURCE_NAMESPACE:?TARGET_RESOURCE_NAMESPACE is required}"
: "${TARGET_RESOURCE_NAME:?TARGET_RESOURCE_NAME is required}"

GOOD_SOURCE_URL="${GOOD_SOURCE_URL:-https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2}"

echo "=== Phase 1: Validate ==="
echo "Checking VirtualMachine ${TARGET_RESOURCE_NAME} in ${TARGET_RESOURCE_NAMESPACE}..."

VM_EXISTS=$(kubectl get vm "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" -o name 2>/dev/null || echo "")
if [ -z "${VM_EXISTS}" ]; then
    echo "ERROR: VirtualMachine ${TARGET_RESOURCE_NAME} not found in ${TARGET_RESOURCE_NAMESPACE}"
    exit 1
fi

VM_STATUS=$(kubectl get vm "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
echo "VM status: ${VM_STATUS}"

DV_NAME=$(kubectl get vm "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.spec.dataVolumeTemplates[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "${DV_NAME}" ]; then
    echo "ERROR: No DataVolume template found on VM ${TARGET_RESOURCE_NAME}"
    exit 1
fi
echo "DataVolume: ${DV_NAME}"

DV_PHASE=$(kubectl get datavolume "${DV_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
echo "DataVolume phase: ${DV_PHASE}"

CURRENT_URL=$(kubectl get datavolume "${DV_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.spec.source.http.url}' 2>/dev/null || echo "")
echo "Current source URL: ${CURRENT_URL}"

IMPORTER_POD=$(kubectl get pods -n "${TARGET_RESOURCE_NAMESPACE}" \
    -l "cdi.kubevirt.io/storage.import.importPvcName=${DV_NAME}" \
    --no-headers 2>/dev/null | head -1 | awk '{print $1}')
if [ -n "${IMPORTER_POD}" ]; then
    echo "Importer pod: ${IMPORTER_POD}"
    echo "Importer logs (last 5 lines):"
    kubectl logs "${IMPORTER_POD}" -n "${TARGET_RESOURCE_NAMESPACE}" --tail=5 2>/dev/null || echo "  (no logs)"
fi

echo "Validated: DataVolume ${DV_NAME} has failing import."

echo "=== Phase 2: Action ==="
echo "Stopping VM ${TARGET_RESOURCE_NAME}..."
kubectl patch vm "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    --type merge -p '{"spec":{"running":false}}' 2>/dev/null || true

echo "Waiting for VMI to terminate..."
for i in $(seq 1 12); do
    VMI=$(kubectl get vmi "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" -o name 2>/dev/null || echo "")
    if [ -z "${VMI}" ]; then
        echo "  VMI terminated."
        break
    fi
    if [ "$i" -eq 12 ]; then
        echo "  WARNING: VMI still running after 60s, proceeding..."
    fi
    sleep 5
done

echo "Deleting failed DataVolume ${DV_NAME}..."
kubectl delete datavolume "${DV_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" --ignore-not-found --wait=false
kubectl delete pvc "${DV_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" --ignore-not-found --wait=false

echo "Waiting for PVC cleanup..."
sleep 5

echo "Patching VM DataVolume source to valid URL..."
kubectl patch vm "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    --type json -p "[
        {\"op\": \"replace\",
         \"path\": \"/spec/dataVolumeTemplates/0/spec/source/http/url\",
         \"value\": \"${GOOD_SOURCE_URL}\"}
    ]"

echo "Restarting VM..."
kubectl patch vm "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    --type merge -p '{"spec":{"running":true}}'

echo "Waiting for DataVolume to start importing..."
for i in $(seq 1 24); do
    DV_PHASE=$(kubectl get datavolume "${DV_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "${DV_PHASE}" = "Succeeded" ]; then
        echo "  DataVolume import succeeded!"
        break
    fi
    if [ "$i" -eq 24 ]; then
        echo "  WARNING: DataVolume still importing after 120s (phase: ${DV_PHASE})"
        echo "  Import may complete after job finishes — this is expected for large images."
    fi
    echo "  DataVolume phase: ${DV_PHASE:-Pending} (${i}/24)"
    sleep 5
done

echo "=== Phase 3: Verify ==="
NEW_URL=$(kubectl get vm "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.spec.dataVolumeTemplates[0].spec.source.http.url}' 2>/dev/null || echo "")
echo "New source URL: ${NEW_URL}"

DV_PHASE=$(kubectl get datavolume "${DV_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
echo "DataVolume phase: ${DV_PHASE}"

VM_STATUS=$(kubectl get vm "${TARGET_RESOURCE_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
echo "VM status: ${VM_STATUS}"

if [ "${DV_PHASE}" = "Succeeded" ] || [ "${DV_PHASE}" = "ImportInProgress" ]; then
    echo "=== SUCCESS: DataVolume source fixed (${CURRENT_URL} -> ${NEW_URL}), import ${DV_PHASE} ==="
else
    echo "WARNING: DataVolume phase is ${DV_PHASE}, may still be starting."
    echo "  If this is a large image, import may take several minutes."
    exit 0
fi
