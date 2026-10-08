#!/usr/bin/env bash
#
# extract-audit-trace.sh — Extract the full audit trail for a RemediationRequest
# from the Kubernaut DataStorage PostgreSQL backend.
#
# Usage:
#   bash scripts/extract-audit-trace.sh <rr-name>             # specific RR
#   bash scripts/extract-audit-trace.sh --latest               # most recent RR
#   bash scripts/extract-audit-trace.sh --all                  # all RRs
#   bash scripts/extract-audit-trace.sh --fleet --latest       # latest RR on fleet hub
#   bash scripts/extract-audit-trace.sh <rr-name> --json       # JSON output
#
# Options:
#   --fleet         Target the fleet hub (requires HUB_KUBECONFIG and SPOKE_KUBECONFIG)
#   --json          Output raw JSON instead of formatted table
#   --investigation Only show AI investigation tool calls and LLM turns
#   --summary       One-line-per-RR summary (phase, workflow, confidence)
#   -o FILE         Write output to file instead of stdout
#   -n NAMESPACE    Kubernaut system namespace (default: kubernaut-system)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/fleet-helper.sh
source "${SCRIPT_DIR}/fleet-helper.sh"

KUBERNAUT_NS="${KUBERNAUT_NS:-kubernaut-system}"
KUBERNAUT_DB_NAME="${KUBERNAUT_DB_NAME:-}"
OUTPUT_FORMAT="table"
FILTER=""
OUTPUT_FILE=""
RR_SELECTOR=""
FLEET_MODE=false

usage() {
    cat <<'EOF'
Usage: bash scripts/extract-audit-trace.sh [--fleet] <rr-name|--latest|--all> [options]

Extract audit events for one or more RemediationRequests from DataStorage PostgreSQL.
By default, kubectl uses the current context. --fleet explicitly targets HUB_KUBECONFIG.

Options:
  --fleet         Target the fleet hub; requires HUB_KUBECONFIG and SPOKE_KUBECONFIG
  --json          Output raw JSON instead of formatted table
  --investigation Only show AI investigation tool calls and LLM turns
  --summary       One-line-per-RR summary (phase, workflow, confidence)
  -o FILE         Write output to file instead of stdout
  -n NAMESPACE    Kubernaut system namespace (default: kubernaut-system)
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fleet)       FLEET_MODE=true; shift ;;
        --latest)      RR_SELECTOR="__latest__"; shift ;;
        --all)         RR_SELECTOR="__all__"; shift ;;
        --json)        OUTPUT_FORMAT="json"; shift ;;
        --investigation) FILTER="investigation"; shift ;;
        --summary)     FILTER="summary"; shift ;;
        -o)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: -o requires a file path." >&2
                usage >&2
                exit 2
            fi
            OUTPUT_FILE="$2"; shift 2 ;;
        -n)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: -n requires a namespace." >&2
                usage >&2
                exit 2
            fi
            KUBERNAUT_NS="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        -*)            echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)             RR_SELECTOR="$1"; shift ;;
    esac
done

if [[ -z "$RR_SELECTOR" ]]; then
    usage >&2
    exit 2
fi

if [[ "$FLEET_MODE" == true ]]; then
    # Match the rest of the fleet entry points: fleet targeting is opt-in and
    # requires both kubeconfigs, even though this read-only query runs on hub.
    fleet_dispatch_requested --fleet
    export KUBECONFIG="$HUB_KUBECONFIG"
fi

find_pg_pod_by_selector() {
    local selector="$1"
    local candidates
    candidates=$(kubectl get pods -n "$KUBERNAUT_NS" -l "$selector" \
        --no-headers -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null) || return 1
    printf '%s\n' "$candidates" | awk '$2 == "Running" { print $1; exit }'
}

PG_POD=$(find_pg_pod_by_selector app=postgresql) || {
    echo "ERROR: Could not list pods in namespace $KUBERNAUT_NS using the selected kubeconfig." >&2
    exit 1
}
if [[ -z "$PG_POD" ]]; then
    PG_POD=$(find_pg_pod_by_selector app.kubernetes.io/name=postgresql) || {
        echo "ERROR: Could not list pods in namespace $KUBERNAUT_NS using the selected kubeconfig." >&2
        exit 1
    }
fi
if [[ -z "$PG_POD" ]]; then
    PG_PODS=$(kubectl get pods -n "$KUBERNAUT_NS" \
        --no-headers -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null) || {
        echo "ERROR: Could not list pods in namespace $KUBERNAUT_NS using the selected kubeconfig." >&2
        exit 1
    }
    PG_POD=$(printf '%s\n' "$PG_PODS" | awk '$2 == "Running" && $1 ~ /^postgresql([-.]|$)/ { print $1; exit }')
fi
if [[ -z "$PG_POD" ]]; then
    echo "ERROR: No running PostgreSQL pod found in $KUBERNAUT_NS (looked for postgresql pod names and app labels)." >&2
    exit 1
fi

secret_value() {
    local key="$1"
    local encoded
    encoded=$(kubectl get secret postgresql-secret -n "$KUBERNAUT_NS" \
        -o "jsonpath={.data.${key}}" 2>/dev/null) || return 1
    [[ -n "$encoded" ]] || return 1
    printf '%s' "$encoded" | base64 -d 2>/dev/null
}

DB_USER="${KUBERNAUT_DB_USER:-}"
DB_PASS="${KUBERNAUT_DB_PASSWORD:-}"
if [[ -z "$DB_USER" ]]; then
    DB_USER=$(secret_value POSTGRES_USER 2>/dev/null) || DB_USER=""
fi
if [[ -z "$DB_USER" ]]; then
    DB_USER=$(secret_value username 2>/dev/null) || DB_USER=""
fi
if [[ -z "$DB_PASS" ]]; then
    DB_PASS=$(secret_value POSTGRES_PASSWORD 2>/dev/null) || DB_PASS=""
fi
if [[ -z "$DB_PASS" ]]; then
    DB_PASS=$(secret_value password 2>/dev/null) || DB_PASS=""
fi
if [[ -z "$KUBERNAUT_DB_NAME" ]]; then
    KUBERNAUT_DB_NAME=$(secret_value POSTGRES_DB 2>/dev/null) || KUBERNAUT_DB_NAME="action_history"
fi
if [[ -z "$DB_USER" || -z "$DB_PASS" ]]; then
    echo "ERROR: Could not read PostgreSQL credentials from postgresql-secret in $KUBERNAUT_NS." >&2
    exit 1
fi

run_sql() {
    local sql="$1"
    kubectl exec -n "$KUBERNAUT_NS" "$PG_POD" -- \
        env PGPASSWORD="$DB_PASS" psql -X -U "$DB_USER" -d "$KUBERNAUT_DB_NAME" \
        --no-align --tuples-only --set=ON_ERROR_STOP=1 -c "$sql"
}

resolve_rr() {
    if [[ "$RR_SELECTOR" == "__latest__" ]]; then
        run_sql "SELECT correlation_id FROM audit_events
                 WHERE event_type IN ('apifrontend.rr.created', 'gateway.crd.created')
                   AND correlation_id IS NOT NULL AND correlation_id <> ''
                 ORDER BY event_timestamp DESC LIMIT 1;"
    elif [[ "$RR_SELECTOR" == "__all__" ]]; then
        run_sql "SELECT correlation_id FROM (
                     SELECT correlation_id, min(event_timestamp) AS created_at
                     FROM audit_events
                     WHERE event_type IN ('apifrontend.rr.created', 'gateway.crd.created')
                       AND correlation_id IS NOT NULL AND correlation_id <> ''
                     GROUP BY correlation_id
                 ) rr_events
                 ORDER BY created_at;"
    else
        echo "$RR_SELECTOR"
    fi
}

build_where() {
    local rr="$1"
    # Correlation IDs are the authoritative RR boundary. Do not truncate the
    # ID to a signal-fingerprint prefix: an initial RR and a recurrence RR can
    # legitimately share that prefix, which would merge their audit traces.
    local rr_sql
    rr_sql=$(printf '%s' "$rr" | sed "s/'/''/g")
    echo "WHERE (correlation_id = '${rr_sql}' OR event_data->>'incident_id' = '${rr_sql}')"
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
                   AND event_type IN ('apifrontend.rr.created', 'gateway.signal.received', 'gateway.crd.created')
                   ORDER BY event_timestamp DESC LIMIT 1),
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
        'workflow_selected', coalesce(
            (SELECT event_data->>'workflow_name'
             FROM audit_events ${where}
             AND event_type = 'workflowexecution.selection.completed'
             ORDER BY event_timestamp DESC LIMIT 1),
            (SELECT event_data->'response_data'->>'selectedWorkflow'
             FROM audit_events ${where}
             AND event_type = 'aiagent.response.complete'
             ORDER BY event_timestamp DESC LIMIT 1)
        ),
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
