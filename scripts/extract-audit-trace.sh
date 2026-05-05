#!/usr/bin/env bash
#
# extract-audit-trace.sh — Extract the full audit trail for a RemediationRequest
# from the Kubernaut DataStorage PostgreSQL backend.
#
# Usage:
#   bash scripts/extract-audit-trace.sh <rr-name>           # specific RR
#   bash scripts/extract-audit-trace.sh --latest             # most recent RR
#   bash scripts/extract-audit-trace.sh --all                # all RRs
#   bash scripts/extract-audit-trace.sh <rr-name> --json     # JSON output
#
# Options:
#   --json          Output raw JSON instead of formatted table
#   --investigation Only show AI investigation tool calls and LLM turns
#   --summary       One-line-per-RR summary (phase, workflow, confidence)
#   -o FILE         Write output to file instead of stdout
#   -n NAMESPACE    Kubernaut system namespace (default: kubernaut-system)
#
set -euo pipefail

KUBERNAUT_NS="${KUBERNAUT_NS:-kubernaut-system}"
OUTPUT_FORMAT="table"
FILTER=""
OUTPUT_FILE=""
RR_SELECTOR=""

usage() {
    sed -n '3,13p' "$0" | sed 's/^# \?//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --latest)      RR_SELECTOR="__latest__"; shift ;;
        --all)         RR_SELECTOR="__all__"; shift ;;
        --json)        OUTPUT_FORMAT="json"; shift ;;
        --investigation) FILTER="investigation"; shift ;;
        --summary)     FILTER="summary"; shift ;;
        -o)            OUTPUT_FILE="$2"; shift 2 ;;
        -n)            KUBERNAUT_NS="$2"; shift 2 ;;
        -h|--help)     usage ;;
        -*)            echo "Unknown option: $1" >&2; usage ;;
        *)             RR_SELECTOR="$1"; shift ;;
    esac
done

[[ -z "$RR_SELECTOR" ]] && usage

PG_POD=$(kubectl get pod -n "$KUBERNAUT_NS" -l app.kubernetes.io/name=postgresql \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$PG_POD" ]]; then
    echo "ERROR: No postgresql pod found in $KUBERNAUT_NS" >&2
    exit 1
fi

DB_USER=$(kubectl get secret postgresql-secret -n "$KUBERNAUT_NS" \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null)
DB_PASS=$(kubectl get secret postgresql-secret -n "$KUBERNAUT_NS" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
if [[ -z "$DB_USER" ]]; then
    DB_USER=$(kubectl get secret postgresql-secret -n "$KUBERNAUT_NS" \
        -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)
    DB_PASS=$(kubectl get secret postgresql-secret -n "$KUBERNAUT_NS" \
        -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
fi

run_sql() {
    local sql="$1"
    local tmpfile
    tmpfile=$(mktemp)
    echo "$sql" > "$tmpfile"
    kubectl cp "$tmpfile" "$KUBERNAUT_NS/$PG_POD:/tmp/_audit_query.sql" 2>/dev/null
    rm -f "$tmpfile"
    kubectl exec -n "$KUBERNAUT_NS" "$PG_POD" -- \
        env PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d action_history \
        --no-align --tuples-only -f /tmp/_audit_query.sql 2>/dev/null
}

resolve_rr() {
    if [[ "$RR_SELECTOR" == "__latest__" ]]; then
        run_sql "SELECT DISTINCT correlation_id FROM audit_events
                 WHERE event_type LIKE 'gateway.crd.created'
                 ORDER BY correlation_id DESC LIMIT 1;"
    elif [[ "$RR_SELECTOR" == "__all__" ]]; then
        run_sql "SELECT DISTINCT correlation_id FROM audit_events
                 WHERE event_type LIKE 'gateway.crd.created'
                 ORDER BY correlation_id;"
    else
        echo "$RR_SELECTOR"
    fi
}

build_where() {
    local rr="$1"
    local fp
    fp=$(echo "$rr" | sed 's/^rr-//' | cut -d- -f1)
    echo "WHERE (correlation_id LIKE '%${fp}%' OR resource_id LIKE '%${fp}%' OR resource_name LIKE '%${fp}%')"
}

extract_summary() {
    local rr="$1"
    local where
    where=$(build_where "$rr")
    run_sql "
    SELECT json_build_object(
        'rr', '${rr}',
        'signal', (SELECT event_data->>'signal_name'
                   FROM audit_events ${where}
                   AND event_type = 'gateway.signal.received' LIMIT 1),
        'signal_mode', (SELECT event_data->>'signal_mode'
                        FROM audit_events ${where}
                        AND event_type = 'signalprocessing.classification.decision' LIMIT 1),
        'severity', (SELECT event_data->>'severity'
                     FROM audit_events ${where}
                     AND event_type = 'signalprocessing.classification.decision' LIMIT 1),
        'model', (SELECT event_data->>'model'
                  FROM audit_events ${where}
                  AND event_type = 'aiagent.llm.request' LIMIT 1),
        'llm_turns', (SELECT count(*)
                      FROM audit_events ${where}
                      AND event_type = 'aiagent.llm.response'),
        'tool_calls', (SELECT count(*)
                       FROM audit_events ${where}
                       AND event_type = 'aiagent.llm.tool_call'),
        'workflow_selected', (SELECT event_data->'response_data'->>'selectedWorkflow'
                              FROM audit_events ${where}
                              AND event_type = 'aiagent.response.complete'
                              ORDER BY event_timestamp DESC LIMIT 1),
        'confidence', (SELECT event_data->'response_data'->>'confidence'
                       FROM audit_events ${where}
                       AND event_type = 'aiagent.response.complete'
                       ORDER BY event_timestamp DESC LIMIT 1),
        'rca_preview', (SELECT substring(event_data->'response_data'->>'rootCauseAnalysis', 1, 300)
                        FROM audit_events ${where}
                        AND event_type = 'aiagent.rca.complete'
                        ORDER BY event_timestamp DESC LIMIT 1),
        'wfe_outcome', (SELECT event_outcome
                        FROM audit_events ${where}
                        AND event_type LIKE 'workflow.%'
                        ORDER BY event_timestamp DESC LIMIT 1),
        'total_events', (SELECT count(*) FROM audit_events ${where}),
        'first_event', (SELECT min(event_timestamp) FROM audit_events ${where}),
        'last_event', (SELECT max(event_timestamp) FROM audit_events ${where})
    );"
}

extract_investigation() {
    local rr="$1"
    local where
    where=$(build_where "$rr")
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        run_sql "
        SELECT json_agg(row_to_json(t) ORDER BY t.event_timestamp) FROM (
            SELECT event_timestamp, event_type, event_action, event_outcome,
                   event_data
            FROM audit_events ${where}
            AND event_type LIKE 'aiagent.%'
            ORDER BY event_timestamp
        ) t;"
    else
        run_sql "
        SELECT event_timestamp,
               event_type,
               CASE
                 WHEN event_type = 'aiagent.llm.request' THEN
                   'model=' || coalesce(event_data->>'model','?') ||
                   ' tokens=' || coalesce(event_data->>'prompt_length','?')
                 WHEN event_type = 'aiagent.llm.response' THEN
                   'tokens=' || coalesce(event_data->>'tokens_used','?') ||
                   ' tools=' || coalesce(event_data->>'tool_call_count','0') ||
                   ' | ' || coalesce(substring(event_data->>'analysis_preview', 1, 120),
                                     substring(event_data->>'analysis_full', 1, 120), '')
                 WHEN event_type = 'aiagent.llm.tool_call' THEN
                   coalesce(event_data->>'tool_name','?') ||
                   '(' || coalesce(substring((event_data->'tool_arguments')::text, 1, 100),'') || ')' ||
                   CASE WHEN (event_data->'tool_result')::text LIKE '%\"error\"%'
                        THEN ' ERR: ' || coalesce(substring(event_data->'tool_result'->>'error', 1, 80),'')
                        ELSE ' -> ' || coalesce(substring(event_data->>'tool_result_preview', 1, 80),
                                                substring((event_data->'tool_result')::text, 1, 80))
                   END
                 WHEN event_type = 'aiagent.response.complete' THEN
                   'workflow=' || coalesce(event_data->'response_data'->>'selectedWorkflow','?') ||
                   ' confidence=' || coalesce(event_data->'response_data'->>'confidence','?') ||
                   ' tokens=' || coalesce(event_data->>'total_prompt_tokens','?') || '/' ||
                   coalesce(event_data->>'total_completion_tokens','?') ||
                   ' | ' || coalesce(substring(event_data->'response_data'->>'analysis',1,120),'')
                 WHEN event_type = 'aiagent.rca.complete' THEN
                   'confidence=' || coalesce(event_data->'response_data'->>'confidence','?') ||
                   ' | ' || coalesce(substring(event_data->'response_data'->>'rootCauseAnalysis',1,200),'')
                 WHEN event_type LIKE 'aiagent.alignment%' OR event_type LIKE 'aiagent.workflow.validation%' THEN
                   'passed=' || coalesce(event_data->>'passed', event_data->>'valid', '?') ||
                   ' | ' || coalesce(substring(event_data::text, 1, 150),'')
                 ELSE substring(event_data::text, 1, 200)
               END as detail
        FROM audit_events ${where}
        AND event_type LIKE 'aiagent.%'
        ORDER BY event_timestamp;"
    fi
}

extract_full() {
    local rr="$1"
    local where
    where=$(build_where "$rr")
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        run_sql "
        SELECT json_agg(row_to_json(t) ORDER BY t.event_timestamp) FROM (
            SELECT event_id, event_timestamp, event_type, event_action,
                   event_outcome, correlation_id, event_data
            FROM audit_events ${where}
            ORDER BY event_timestamp
        ) t;"
    else
        run_sql "
        SELECT event_timestamp,
               event_type,
               event_outcome,
               substring(event_data::text, 1, 300) as data
        FROM audit_events ${where}
        ORDER BY event_timestamp;"
    fi
}

do_extract() {
    local rr="$1"
    echo "=== Audit Trace: ${rr} ==="
    echo ""
    case "$FILTER" in
        summary)       extract_summary "$rr" ;;
        investigation) extract_investigation "$rr" ;;
        *)             extract_full "$rr" ;;
    esac
    echo ""
}

RR_LIST=$(resolve_rr)
if [[ -z "$RR_LIST" ]]; then
    echo "No RemediationRequests found." >&2
    exit 1
fi

if [[ -n "$OUTPUT_FILE" ]]; then
    exec > "$OUTPUT_FILE"
    echo "Writing to $OUTPUT_FILE" >&2
fi

while IFS= read -r rr; do
    [[ -z "$rr" ]] && continue
    do_extract "$rr"
done <<< "$RR_LIST"
