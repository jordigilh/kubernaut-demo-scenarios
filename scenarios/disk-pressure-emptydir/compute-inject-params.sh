#!/usr/bin/env bash
# Compute auto-tuned parameters for the disk-pressure data growth injection.
#
# The PostgreSQL stored procedure simulate_data_growth(batch_size, iterations,
# sleep_ms) must be called with parameters tailored to the target node's
# filesystem capacity. Writing too fast exhausts disk before the pipeline
# completes; too slow and predict_linear() never fires.
#
# This script reads the node's filesystem stats and outputs the computed
# parameters along with a ready-to-paste kubectl command.
#
# Usage:
#   bash scenarios/disk-pressure-emptydir/compute-inject-params.sh
#
# The script is read-only — it does NOT start the injection. Copy the
# printed command and run it when you are ready.
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo-diskpressure}"

POD=$(kubectl get pod -n "${NAMESPACE}" -l app=postgres-emptydir \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
    echo "ERROR: No postgres-emptydir pod found in ${NAMESPACE}."
    echo "       Run setup first: ./scenarios/disk-pressure-emptydir/run.sh setup"
    exit 1
fi

NODE=$(kubectl get pod "$POD" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}')

# OCP sclorg image stores data under /var/lib/pgsql/data; upstream uses
# /var/lib/postgresql/data. Pick whichever exists.
PG_DATA_MOUNT="/var/lib/pgsql/data"
if ! kubectl exec -n "${NAMESPACE}" "${POD}" -- stat "${PG_DATA_MOUNT}" &>/dev/null; then
    PG_DATA_MOUNT="/var/lib/postgresql/data"
fi

DF_LINE=$(kubectl exec -n "${NAMESPACE}" "${POD}" -- df -B1 "${PG_DATA_MOUNT}" 2>/dev/null | tail -1)
TOTAL_BYTES=$(echo "$DF_LINE" | awk '{print $2}')
AVAIL_BYTES=$(echo "$DF_LINE" | awk '{print $4}')

if [ -z "$TOTAL_BYTES" ] || [ -z "$AVAIL_BYTES" ]; then
    echo "ERROR: Could not read filesystem stats from pod ${POD}."
    exit 1
fi

AVAIL_MB=$(( AVAIL_BYTES / 1048576 ))
TOTAL_MB=$(( TOTAL_BYTES / 1048576 ))
THRESHOLD_MB=$(( TOTAL_MB * 15 / 100 ))   # kubelet default eviction: 15%
USABLE_MB=$(( AVAIL_MB - THRESHOLD_MB ))

MIN_USABLE_MB="${MIN_USABLE_MB:-50}"
if [ "$USABLE_MB" -lt "$MIN_USABLE_MB" ]; then
    echo "ERROR: Only ${USABLE_MB} MB usable on ${NODE} (need >= ${MIN_USABLE_MB} MB)."
    echo "       Free disk or reset the constrained filesystem first."
    exit 1
fi

# ── Rate calculation ────────────────────────────────────────────────────
#
# PrometheusRule: predict_linear(v[3m], 1200) < 0  for 1m
#   W=180s window, H=1200s horizon, F=60s for-clause
#   margin=480s (~8 min for LLM + approve + AWX + pg_dump + sync + restore)
#
# Case A (window-limited): fill fast so [3m] window is the bottleneck.
#   Alert fires at W+F=4 min. R = usable / (W+F+margin)
# Case B (slope-limited): minimum rate for desired margin.
#   R = threshold / (H-F-margin)
#
# PostgreSQL disk amplification ~2x (tuple headers, WAL, TOAST).
PG_AMP=2

RATE_MB_S=$(awk "BEGIN {
    avail=${AVAIL_MB}; usable=${USABLE_MB}; threshold=${THRESHOLD_MB}
    W=180; H=1200; F=60; margin=480

    r_fast = usable / (W + F + margin)
    r_min  = avail / (W + H)
    r_slow = threshold / (H - F - margin)

    if (r_fast > r_min) { r = r_fast } else { r = r_slow }

    if (usable < 1024) {
        if (r < 0.1) r = 0.1; if (r > 5) r = 5
    } else if (usable < 10240) {
        if (r < 1.5) r = 1.5; if (r > 5) r = 5
    } else {
        if (r < 5) r = 5; if (r > 60) r = 60
    }
    printf \"%.1f\", r
}")

SLEEP_MS=50
BATCH_SIZE=$(awk "BEGIN { v=int(${RATE_MB_S}*${SLEEP_MS}/1000*1024/${PG_AMP}); if(v<10)v=10; print v }")
ITERATIONS=$(awk "BEGIN { print int(${USABLE_MB}*1024/${BATCH_SIZE})+1000 }")

EST_ALERT_MIN=$(awk "BEGIN {
    r=${RATE_MB_S}*60; W=3; H=20; F=1
    t_slope = ${AVAIL_MB}/r - H + F
    t_window = W + F
    t = (t_slope > t_window) ? t_slope : t_window
    printf \"%.0f\", t
}")
EST_EVICT_MIN=$(awk "BEGIN { printf \"%.0f\", ${USABLE_MB}/(${RATE_MB_S}*60) }")

echo "============================================="
echo " Disk-Pressure Injection Parameters"
echo "============================================="
echo ""
echo "  Pod:        ${POD}"
echo "  Node:       ${NODE}"
echo "  Disk:       ${TOTAL_MB} MB total, ${AVAIL_MB} MB available"
echo "  Threshold:  ${THRESHOLD_MB} MB (15% kubelet eviction)"
echo "  Usable:     ${USABLE_MB} MB"
echo ""
echo "  Rate:       ${RATE_MB_S} MB/s"
echo "  Batch size: ${BATCH_SIZE} rows"
echo "  Iterations: ${ITERATIONS}"
echo "  Sleep:      ${SLEEP_MS} ms between batches"
echo ""
echo "  Estimated timing:"
echo "    PredictedDiskPressure alert:  ~${EST_ALERT_MIN} min"
echo "    Kubelet eviction:             ~${EST_EVICT_MIN} min"
echo "    Pipeline margin:              ~$(( EST_EVICT_MIN - EST_ALERT_MIN )) min"
echo ""
echo "============================================="
echo " Ready-to-run command (copy & paste):"
echo "============================================="
echo ""
echo "  kubectl exec -n ${NAMESPACE} ${POD} -- \\"
echo "    psql -U postgres -d postgres -c \"CALL simulate_data_growth(${BATCH_SIZE}, ${ITERATIONS}, ${SLEEP_MS});\" &"
echo ""
