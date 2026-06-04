#!/usr/bin/env bash
# rerun-failed-scenarios.sh — Re-run scenarios that failed in the parallel
# regression run after fixes have been applied. Runs sequentially to avoid
# LLM concurrency issues that caused some of the original failures.
#
# Usage:
#   tmux new -d -s rerun 'bash scripts/rerun-failed-scenarios.sh 2>&1 | tee rerun-failed.log'
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

RESULTS_DIR="${REPO_ROOT}/rerun-results-${TIMESTAMP}"
LOGS_DIR="${REPO_ROOT}/rerun-logs-${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}" "${LOGS_DIR}"

FAILED_SCENARIOS=(
    network-policy-block
    duplicate-alert-suppression
    orphaned-pvc-no-action
    statefulset-pvc-failure
    concurrent-cross-namespace
    db-connection-saturation
    red-herring-noise
    cascading-service-failure
    scc-violation
)

echo "============================================="
echo " v1.5 Failed Scenario Re-run"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================="
echo ""
echo "  Scenarios: ${FAILED_SCENARIOS[*]}"
echo "  Results:   ${RESULTS_DIR}"
echo "  Logs:      ${LOGS_DIR}"
echo ""

source "${SCRIPT_DIR}/platform-helper.sh"

TRANSCRIPTS_DIR="${REPO_ROOT}/golden-transcripts"

# Archive current golden transcripts before overwriting with re-run results.
# This preserves the first-pass transcripts (including PASS scenarios) as a
# timestamped snapshot in case we need to diff or roll back.
PRE_ARCHIVE="${TRANSCRIPTS_DIR}/archive/pre-rerun-${TIMESTAMP}"
mkdir -p "${PRE_ARCHIVE}"
echo "==> Archiving current golden transcripts to ${PRE_ARCHIVE}/"
for f in "${TRANSCRIPTS_DIR}"/*.json; do
    [ -f "$f" ] && cp "$f" "${PRE_ARCHIVE}/"
done
echo "  Archived $(ls "${PRE_ARCHIVE}"/*.json 2>/dev/null | wc -l | tr -d ' ') transcripts"
echo ""

export KUBERNAUT_BATCH_SETUP_DONE=1
export WAIT_FOR_RR_TIMEOUT=300
export POLL_PIPELINE_TIMEOUT=1200

PASS=0
FAIL=0
TOTAL=${#FAILED_SCENARIOS[@]}

for scenario in "${FAILED_SCENARIOS[@]}"; do
    echo "════════════════════════════════════════════════════════════════════════"
    echo "  RUNNING: ${scenario}"
    echo "════════════════════════════════════════════════════════════════════════"
    echo "  Started: $(date -u '+%H:%M:%S UTC')"

    set +e
    START_S=$(date +%s)
    bash "${SCRIPT_DIR}/overnight-ocp-validation.sh" \
        --skip-seed "--only=${scenario}" \
        > "${LOGS_DIR}/${scenario}.log" 2>&1
    EXIT_CODE=$?
    END_S=$(date +%s)
    ELAPSED=$(( END_S - START_S ))
    set -e

    if [ $EXIT_CODE -eq 0 ]; then
        echo "  PASS  ${scenario}  (${ELAPSED}s)"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL  ${scenario}  exit=${EXIT_CODE} (${ELAPSED}s)"
        echo "  Log: ${LOGS_DIR}/${scenario}.log"
        echo "  --- last 20 lines ---"
        tail -20 "${LOGS_DIR}/${scenario}.log" 2>/dev/null | sed 's/^/  |  /'
        FAIL=$(( FAIL + 1 ))
    fi

    echo "  Finished: $(date -u '+%H:%M:%S UTC')"
    echo ""

    sleep 30
done

echo "============================================="
echo " Re-run Complete"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================="
echo ""
echo "  PASS: ${PASS}/${TOTAL}"
echo "  FAIL: ${FAIL}/${TOTAL}"
echo ""
echo "  Logs: ${LOGS_DIR}/"
echo ""

# Verify golden transcripts were captured for each re-run scenario
echo "==> Golden Transcript Status:"
for scenario in "${FAILED_SCENARIOS[@]}"; do
    matches=$(ls "${TRANSCRIPTS_DIR}/${scenario}-"*.json 2>/dev/null | wc -l | tr -d ' ')
    if [ "$matches" -gt 0 ]; then
        for f in "${TRANSCRIPTS_DIR}/${scenario}-"*.json; do
            ts=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f" 2>/dev/null || stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)
            phase=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('metadata',{}).get('rr_phase','?'))" 2>/dev/null || echo "?")
            outcome=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('metadata',{}).get('rr_outcome','?'))" 2>/dev/null || echo "?")
            echo "  [OK]   ${scenario}: $(basename "$f") (${phase}/${outcome}, ${ts})"
        done
    else
        echo "  [MISS] ${scenario}: no golden transcript found"
    fi
done
echo ""
echo "  Pre-rerun archive: ${PRE_ARCHIVE}/"
echo "  Transcripts dir:   ${TRANSCRIPTS_DIR}/"
echo ""

if [ $FAIL -ne 0 ]; then
    echo "  Some scenarios still failing. Review logs for details."
    exit 1
fi
