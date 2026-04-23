#!/usr/bin/env bash
# Capture an LLM eval transcript from the audit_events DB and AIAnalysis CR.
#
# Replaces the stale log-regex path in capture-transcript.sh (#333) with a
# DB-backed approach. The audit_events table stores structured LLM traces
# (tool calls, token counts, prompts) with 7-year retention, correlated by
# the RemediationRequest name.
#
# Usage:
#   bash scripts/capture-eval.sh [--rr NAME] [--namespace NS] [--scenario NAME] [--output DIR]
#
# Options:
#   --rr NAME        Target a specific RemediationRequest (default: latest)
#   --namespace NS   Filter RRs by signal target namespace (for multi-RR
#                    scenarios like concurrent-cross-namespace)
#   --scenario NAME  Override auto-detected scenario name (must match eval-matrix key)
#   --output DIR     Output directory (default: golden-transcripts/)
#   --wait           Wait for the RR to reach a terminal phase before capture
#
# Output: golden-transcripts/<scenario>-<signal>.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

RR_NAME=""
TARGET_NS=""
SCENARIO_OVERRIDE=""
OUTPUT_DIR="${REPO_ROOT}/golden-transcripts"
WAIT_FOR_COMPLETE=false
PLATFORM_NS="kubernaut-system"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rr)        RR_NAME="$2"; shift 2 ;;
        --namespace) TARGET_NS="$2"; shift 2 ;;
        --scenario)  SCENARIO_OVERRIDE="$2"; shift 2 ;;
        --output)    OUTPUT_DIR="$2"; shift 2 ;;
        --wait)      WAIT_FOR_COMPLETE=true; shift ;;
        *)           echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

psql_readonly() {
    local query="$1"
    local attempt=0
    local result=""
    while (( attempt < 3 )); do
        result=$(kubectl exec -n "$PLATFORM_NS" deploy/postgresql -- \
            psql -U slm_user -d action_history -t -A \
            --set=ON_ERROR_STOP=1 -c "$query" 2>/dev/null) && break
        attempt=$((attempt + 1))
        echo "  WARN: psql attempt $attempt failed, retrying in 5s..." >&2
        sleep 5
    done
    if (( attempt >= 3 )); then
        echo "ERROR: psql query failed after 3 attempts" >&2
        return 1
    fi
    echo "$result"
}

# ── Find the target RR ──────────────────────────────────────────────────────

if [ -z "$RR_NAME" ]; then
    if [ -n "$TARGET_NS" ]; then
        RR_NAME=$(kubectl get rr -n "$PLATFORM_NS" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
            | awk -v ns="$TARGET_NS" '$2 == ns {print $1}' \
            | tail -1)
    else
        RR_NAME=$(kubectl get rr -n "$PLATFORM_NS" \
            -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)
    fi
    if [ -z "$RR_NAME" ]; then
        echo "ERROR: No RemediationRequest found in $PLATFORM_NS"
        exit 1
    fi
fi
echo "==> Capturing eval transcript for RR: $RR_NAME"

# ── Wait for terminal phase (optional) ──────────────────────────────────────

if [ "$WAIT_FOR_COMPLETE" = true ]; then
    echo "  Waiting for RR to reach terminal phase..."
    for _ in $(seq 1 120); do
        PHASE=$(kubectl get rr "$RR_NAME" -n "$PLATFORM_NS" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
        case "$PHASE" in
            Completed|TimedOut|Failed|ManualIntervention) break ;;
        esac
        sleep 5
    done
    echo "  RR phase: $PHASE"
fi

# ── Wait for audit flush ────────────────────────────────────────────────────

echo "  Waiting for audit flush (3s)..."
sleep 3

AUDIT_COUNT=$(psql_readonly "
    SELECT count(*) FROM audit_events
    WHERE correlation_id = '$RR_NAME'
      AND event_type = 'aiagent.llm.request'
")

if [ "${AUDIT_COUNT:-0}" -eq 0 ]; then
    echo "  WARN: No audit events yet, retrying in 5s..."
    sleep 5
    AUDIT_COUNT=$(psql_readonly "
        SELECT count(*) FROM audit_events
        WHERE correlation_id = '$RR_NAME'
          AND event_type = 'aiagent.llm.request'
    ")
fi
echo "  Audit events: $AUDIT_COUNT LLM request(s)"

# ── Extract AA CR ────────────────────────────────────────────────────────────

AA_NAME="ai-${RR_NAME}"
AA_JSON=$(kubectl get aianalysis "$AA_NAME" -n "$PLATFORM_NS" -o json 2>/dev/null) || {
    echo "ERROR: AIAnalysis $AA_NAME not found"
    exit 1
}

SESSION_ID=$(echo "$AA_JSON" | python3 -c "
import json, sys
aa = json.load(sys.stdin)
print(aa.get('status', {}).get('investigationSession', {}).get('id', ''))
")
echo "  Session ID: $SESSION_ID"

# ── Extract structured analysis ──────────────────────────────────────────────

AA_STRUCTURED=$(echo "$AA_JSON" | python3 -c "
import json, sys

aa = json.load(sys.stdin)
spec = aa.get('spec', {})
status = aa.get('status', {})
signal = spec.get('analysisRequest', {}).get('signalContext', {})

result = {
    'remediationId': spec.get('remediationId'),
    'signal': {
        'signalName': signal.get('signalName'),
        'severity': signal.get('severity'),
        'environment': signal.get('environment'),
        'targetResource': signal.get('targetResource'),
        'businessPriority': signal.get('businessPriority'),
    },
    'investigation': {
        'sessionId': status.get('investigationSession', {}).get('id'),
        'durationMs': status.get('investigationTime'),
        'pollCount': status.get('investigationSession', {}).get('pollCount'),
    },
    'rootCauseAnalysis': status.get('rootCauseAnalysis'),
    'rootCauseSummary': status.get('rootCause'),
    'postRCAContext': status.get('postRCAContext', {}).get('detectedLabels'),
    'selectedWorkflow': status.get('selectedWorkflow'),
    'alternativeWorkflows': status.get('alternativeWorkflows'),
    'actionability': status.get('actionability'),
    'approvalRequired': status.get('approvalRequired'),
    'approvalReason': status.get('approvalReason'),
    'needsHumanReview': status.get('needsHumanReview'),
    'humanReviewReason': status.get('humanReviewReason'),
    'phase': status.get('phase'),
}

print(json.dumps(result, indent=2))
")

# ── Workaround #769: source RCA from audit event if AA discarded it ──────────

NEEDS_RCA_FALLBACK=$(echo "$AA_STRUCTURED" | python3 -c "
import json, sys
a = json.load(sys.stdin)
rca = a.get('rootCauseAnalysis')
review = a.get('humanReviewReason')
print('true' if (not rca and review == 'no_matching_workflows') else 'false')
")

if [ "$NEEDS_RCA_FALLBACK" = "true" ]; then
    echo "  NOTE: AA discarded RCA (#769), sourcing from audit event..."
    RCA_FROM_AUDIT=$(psql_readonly "
        SELECT event_data->'response_data'->>'rootCauseAnalysis'
        FROM audit_events
        WHERE correlation_id = '$RR_NAME'
          AND event_type = 'aiagent.response.complete'
        ORDER BY event_timestamp DESC LIMIT 1
    ")
    if [ -n "$RCA_FROM_AUDIT" ] && [ "$RCA_FROM_AUDIT" != "" ]; then
        AA_STRUCTURED=$(echo "$AA_STRUCTURED" | python3 -c "
import json, sys
a = json.load(sys.stdin)
rca_raw = '''$RCA_FROM_AUDIT'''
try:
    a['rootCauseAnalysis'] = json.loads(rca_raw)
    a['rootCauseSummary'] = a['rootCauseAnalysis'].get('summary', '')
    a['_rca_source'] = 'audit_event_fallback'
except (json.JSONDecodeError, TypeError):
    a['_rca_source'] = 'audit_event_fallback_failed'
print(json.dumps(a, indent=2))
")
    fi
fi

# ── Extract LLM trace from audit_events ──────────────────────────────────────

echo "  Extracting LLM trace from audit_events..."

LLM_TRACE=$(psql_readonly "
    SELECT json_agg(row_to_json(t)) FROM (
        SELECT
            event_type,
            event_timestamp,
            event_data->>'model' as model,
            event_data->>'prompt_length' as prompt_length,
            event_data->>'tokens_used' as tokens_used,
            event_data->>'tool_call_count' as tool_call_count,
            event_data->>'tool_name' as tool_name,
            event_data->>'tool_call_index' as tool_call_index,
            event_data->>'tool_arguments' as tool_arguments,
            event_data->>'tool_result' as tool_result,
            event_data->>'has_analysis' as has_analysis,
            event_data->>'analysis_preview' as analysis_preview
        FROM audit_events
        WHERE correlation_id = '$RR_NAME'
          AND event_type LIKE 'aiagent.llm.%'
        ORDER BY event_timestamp
    ) t
")

# Also extract the complete KA response for escalation scenarios
KA_RESPONSE=$(psql_readonly "
    SELECT event_data->>'response_data'
    FROM audit_events
    WHERE correlation_id = '$RR_NAME'
      AND event_type = 'aiagent.response.complete'
    ORDER BY event_timestamp DESC LIMIT 1
")

# ── Compute summary stats ────────────────────────────────────────────────────

TRACE_STATS=$(echo "$LLM_TRACE" | python3 -c "
import json, sys

raw = sys.stdin.read().strip()
if not raw or raw == '':
    print(json.dumps({'totalTokens': 0, 'llmTurns': 0, 'totalToolCalls': 0, 'k8sToolCalls': 0, 'model': ''}))
    sys.exit(0)

events = json.loads(raw)
total_tokens = 0
llm_turns = 0
total_tool_calls = 0
k8s_tool_calls = 0
model = ''
planning_tools = {'todo_write', 'submit_result'}

for e in events:
    if e['event_type'] == 'aiagent.llm.request':
        llm_turns += 1
        if not model and e.get('model'):
            model = e['model']
    elif e['event_type'] == 'aiagent.llm.response':
        tokens = e.get('tokens_used')
        if tokens:
            total_tokens += int(tokens)
    elif e['event_type'] == 'aiagent.llm.tool_call':
        total_tool_calls += 1
        tool = e.get('tool_name', '')
        if tool not in planning_tools:
            k8s_tool_calls += 1

print(json.dumps({
    'totalTokens': total_tokens,
    'llmTurns': llm_turns,
    'totalToolCalls': total_tool_calls,
    'k8sToolCalls': k8s_tool_calls,
    'model': model,
}))
")

# ── Get RR and EA details ────────────────────────────────────────────────────

RR_JSON=$(kubectl get rr "$RR_NAME" -n "$PLATFORM_NS" -o json 2>/dev/null)

RR_PHASE=$(echo "$RR_JSON" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print(r.get('status',{}).get('overallPhase',''))
")

RR_OUTCOME=$(echo "$RR_JSON" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print(r.get('status',{}).get('outcome',''))
")

EA_NAME="ea-${RR_NAME}"
EA_SCORES=$(kubectl get effectivenessassessment "$EA_NAME" -n "$PLATFORM_NS" -o json 2>/dev/null | python3 -c "
import json, sys
ea = json.load(sys.stdin)
c = ea.get('status', {}).get('components', {})
print(json.dumps({
    'metricsScore': c.get('metricsScore'),
    'alertScore': c.get('alertScore'),
    'healthScore': c.get('healthScore'),
}, indent=2))
" 2>/dev/null || echo '{}')

# ── Metadata ─────────────────────────────────────────────────────────────────

KA_IMAGE=$(kubectl get pod -n "$PLATFORM_NS" -l app=kubernaut-agent \
    -o jsonpath='{.items[0].status.containerStatuses[0].image}' 2>/dev/null || echo "unknown")

CHART_VERSION=$(helm list -n "$PLATFORM_NS" -o json 2>/dev/null | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    if r.get('name') == 'kubernaut':
        print(r.get('app_version', 'unknown'))
        break
" 2>/dev/null || echo "unknown")

CLUSTER_NAME=$(kubectl config current-context 2>/dev/null || echo "unknown")

# ── Derive scenario name ────────────────────────────────────────────────────

if [ -n "$SCENARIO_OVERRIDE" ]; then
    SCENARIO="$SCENARIO_OVERRIDE"
else
    SCENARIO=$(python3 -c "
import json, sys

NS_TO_SCENARIO = {
    'demo-quota': 'resource-quota-exhaustion',
    'demo-orphaned-pvc': 'orphaned-pvc-no-action',
    'demo-netpol': 'network-policy-block',
    'demo-hpa': 'hpa-maxed',
    'demo-alert-dup': 'duplicate-alert-suppression',
    'demo-alpha-staging': 'concurrent-cross-namespace',
    'demo-beta-production': 'concurrent-cross-namespace',
    'demo-statefulset-pvc': 'statefulset-pvc-failure',
    'demo-mesh': 'mesh-routing-failure',
    'demo-disk-pressure': 'disk-pressure-emptydir',
}

rr = json.loads(sys.argv[1])
aa = json.loads(sys.argv[2])

ns = rr.get('status',{}).get('remediationTarget',{}).get('namespace','')
if not ns:
    ns = rr.get('status',{}).get('signalTarget',{}).get('namespace','')
if not ns:
    ns = aa.get('spec',{}).get('analysisRequest',{}).get('signalContext',{}).get('targetResource',{}).get('namespace','')
if not ns:
    labels = rr.get('metadata',{}).get('labels',{})
    ns = labels.get('kubernaut.io/namespace', '')

if ns in NS_TO_SCENARIO:
    print(NS_TO_SCENARIO[ns])
else:
    scenario = ns.replace('demo-', '') if ns.startswith('demo-') else (ns or 'unknown')
    print(scenario)
" "$RR_JSON" "$AA_JSON" 2>/dev/null || echo "unknown")
fi

SIGNAL_NAME=$(echo "$AA_JSON" | python3 -c "
import json, sys
aa = json.load(sys.stdin)
print(aa.get('spec',{}).get('analysisRequest',{}).get('signalContext',{}).get('signalName','unknown'))
")

# ── Assemble golden transcript ───────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"
OUTFILE="${OUTPUT_DIR}/${SCENARIO}-${SIGNAL_NAME,,}.json"

python3 -c "
import json, sys
from datetime import datetime, timezone

aa = json.loads(sys.argv[1])
trace_raw = sys.argv[2]
trace_stats = json.loads(sys.argv[3])
ea_scores = json.loads(sys.argv[4])
ka_response_raw = sys.argv[5]

trace = json.loads(trace_raw) if trace_raw and trace_raw.strip() else []
try:
    ka_response = json.loads(ka_response_raw) if ka_response_raw and ka_response_raw.strip() else {}
except (json.JSONDecodeError, TypeError):
    ka_response = {}

transcript = {
    'schema_version': 1,
    '_metadata': {
        'captured_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'ka_image': sys.argv[6],
        'model': trace_stats.get('model', ''),
        'cluster': sys.argv[7],
        'chart_version': sys.argv[8],
    },
    'scenario': sys.argv[9],
    'signalName': sys.argv[10],
    'remediationRequest': {
        'name': sys.argv[11],
        'phase': sys.argv[12],
        'outcome': sys.argv[13],
    },
    'analysis': aa,
    'llmTrace': trace,
    'traceStats': trace_stats,
    'kaResponse': ka_response,
    'effectivenessAssessment': ea_scores,
}
print(json.dumps(transcript, indent=2))
" \
    "$AA_STRUCTURED" \
    "$LLM_TRACE" \
    "$TRACE_STATS" \
    "$EA_SCORES" \
    "$KA_RESPONSE" \
    "$KA_IMAGE" \
    "$CLUSTER_NAME" \
    "$CHART_VERSION" \
    "$SCENARIO" \
    "$SIGNAL_NAME" \
    "$RR_NAME" \
    "$RR_PHASE" \
    "$RR_OUTCOME" \
    > "$OUTFILE"

# ── Summary ──────────────────────────────────────────────────────────────────

MODEL=$(echo "$TRACE_STATS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('model',''))")
TOKENS=$(echo "$TRACE_STATS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('totalTokens',0))")
TURNS=$(echo "$TRACE_STATS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('llmTurns',0))")
TOOLS=$(echo "$TRACE_STATS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('totalToolCalls',0))")

echo ""
echo "==> Eval transcript saved to: $OUTFILE"
echo "    Scenario:    $SCENARIO"
echo "    Signal:      $SIGNAL_NAME"
echo "    RR:          $RR_NAME ($RR_PHASE / $RR_OUTCOME)"
echo "    Model:       $MODEL"
echo "    Tokens:      $TOKENS"
echo "    LLM turns:   $TURNS"
echo "    Tool calls:  $TOOLS"
