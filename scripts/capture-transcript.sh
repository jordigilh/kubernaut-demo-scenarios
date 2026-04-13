#!/usr/bin/env bash
# Capture a golden transcript from the most recent HAPI investigation session.
#
# Extracts the LLM dialog (tool calls, AI responses, workflow selection) from
# the kubernaut-agent logs and the AIAnalysis CR, then writes a structured JSON
# file suitable for Mock LLM validation (see issue #296).
#
# Usage:
#   bash scripts/capture-transcript.sh [--rr NAME] [--output DIR]
#
# If --rr is omitted, the most recent RemediationRequest is used.
# Default output directory: golden-transcripts/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

RR_NAME=""
OUTPUT_DIR="${REPO_ROOT}/golden-transcripts"
WAIT_FOR_COMPLETE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rr)       RR_NAME="$2"; shift 2 ;;
        --output)   OUTPUT_DIR="$2"; shift 2 ;;
        --wait)     WAIT_FOR_COMPLETE=true; shift ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

NS="kubernaut-system"

# Find the target RR
if [ -z "$RR_NAME" ]; then
    RR_NAME=$(kubectl get rr -n "$NS" -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)
    if [ -z "$RR_NAME" ]; then
        echo "ERROR: No RemediationRequest found in $NS"
        exit 1
    fi
fi
echo "==> Capturing transcript for RR: $RR_NAME"

# Optionally wait for the RR to reach a terminal phase
if [ "$WAIT_FOR_COMPLETE" = true ]; then
    echo "  Waiting for RR to reach terminal phase..."
    for i in $(seq 1 120); do
        PHASE=$(kubectl get rr "$RR_NAME" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
        case "$PHASE" in
            Completed|TimedOut|Failed|ManualIntervention)
                echo "  RR reached phase: $PHASE"
                break
                ;;
        esac
        sleep 5
    done
fi

# Get the AA CR name (convention: ai-<rr-name>)
AA_NAME="ai-${RR_NAME}"
AA_JSON=$(kubectl get aianalysis "$AA_NAME" -n "$NS" -o json 2>/dev/null) || {
    echo "ERROR: AIAnalysis $AA_NAME not found"
    exit 1
}

# Extract session ID
SESSION_ID=$(echo "$AA_JSON" | python3 -c "
import json, sys
aa = json.load(sys.stdin)
print(aa.get('status', {}).get('investigationSession', {}).get('id', ''))
")

if [ -z "$SESSION_ID" ]; then
    echo "ERROR: No session ID found in $AA_NAME"
    exit 1
fi
echo "  Session ID: $SESSION_ID"

# Extract structured data from the AA CR
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
}

print(json.dumps(result, indent=2))
")

# Capture HAPI logs for this session (filter out health probes)
echo "  Extracting HAPI logs for session $SESSION_ID..."
HAPI_LOGS=$(kubectl logs -n "$NS" deployment/kubernaut-agent --tail=10000 2>/dev/null \
    | grep -v '/ready\|/health\|readiness_check\|health_check\|Timer tick\|Timer-based\|audit-store\|HAPI FLUSH\|DD-AUDIT' \
    | grep -E "$SESSION_ID|AI:\[/bold|Running tool #|Finished #|list_available_actions|list_workflows|get_workflow|get_namespaced_resource|LiteLLM completion|Wrapper: Completed|Investigation Tasks|incident_analysis_started|phase[123]_|workflow_selection" \
    || echo "")

# Parse HAPI logs into structured tool calls
TOOL_CALLS=$(echo "$HAPI_LOGS" | python3 -c "
import sys, json, re

lines = sys.stdin.read().strip().split('\n')
tool_calls = []
ai_messages = []
llm_model = ''
llm_call_count = 0

for line in lines:
    if not line.strip():
        continue
    # Tool invocations
    m = re.search(r'Running tool #(\d+) \[bold\](\w+)\[/bold\]: (.+)', line)
    if m:
        tool_calls.append({
            'index': int(m.group(1)),
            'tool': m.group(2),
            'description': m.group(3),
        })
        continue
    # Tool completions
    m = re.search(r'Finished #(\d+) in ([\d.]+)s, output length: ([\d,]+) characters', line)
    if m:
        idx = int(m.group(1))
        for tc in tool_calls:
            if tc['index'] == idx and 'durationSec' not in tc:
                tc['durationSec'] = float(m.group(2))
                tc['outputChars'] = int(m.group(3).replace(',', ''))
                break
        continue
    # AI messages (format: [bold #00FFFF]AI:[/bold #00FFFF] message text)
    m = re.search(r'AI:\[/bold[^\]]*\]\s*(.+)', line)
    if m:
        ai_messages.append(m.group(1).strip())
        continue
    # LLM calls
    m = re.search(r'LiteLLM completion\(\) model= (.+?); provider = (.+)', line)
    if m:
        if not llm_model:
            llm_model = f'{m.group(1)} ({m.group(2)})'
        llm_call_count += 1
        continue

result = {
    'toolCalls': tool_calls,
    'aiMessages': ai_messages,
    'llmModel': llm_model,
    'llmCallCount': llm_call_count,
}
print(json.dumps(result, indent=2))
" 2>/dev/null || echo '{"toolCalls":[],"aiMessages":[]}')

# Get RR and EA details
RR_JSON=$(kubectl get rr "$RR_NAME" -n "$NS" -o json 2>/dev/null)
RR_PHASE=$(echo "$RR_JSON" | python3 -c "
import json,sys
r=json.load(sys.stdin)
conditions = r.get('status',{}).get('conditions',[])
for c in conditions:
    if c.get('type') == 'Ready':
        print(c.get('reason',''))
        break
else:
    print('')
")
RR_OUTCOME=$(echo "$RR_JSON" | python3 -c "
import json,sys
r=json.load(sys.stdin)
conditions = r.get('status',{}).get('conditions',[])
for c in conditions:
    if c.get('type') == 'Succeeded':
        print(c.get('reason',''))
        break
else:
    # Fallback: if wide output shows an outcome column, check additional fields
    print(r.get('status',{}).get('outcome',''))
")

EA_NAME="ea-${RR_NAME}"
EA_SCORES=$(kubectl get effectivenessassessment "$EA_NAME" -n "$NS" -o json 2>/dev/null | python3 -c "
import json, sys
ea = json.load(sys.stdin)
c = ea.get('status', {}).get('components', {})
print(json.dumps({
    'metricsScore': c.get('metricsScore'),
    'alertScore': c.get('alertScore'),
    'healthScore': c.get('healthScore'),
    'metricsAssessed': c.get('metricsAssessed'),
    'alertAssessed': c.get('alertAssessed'),
    'healthAssessed': c.get('healthAssessed'),
}, indent=2))
" 2>/dev/null || echo '{}')

# Get Helm chart version
CHART_VERSION=$(helm list -n "$NS" -o json 2>/dev/null | python3 -c "
import json, sys
releases = json.load(sys.stdin)
for r in releases:
    if r.get('name') == 'kubernaut':
        print(r.get('app_version', 'unknown'))
        break
" 2>/dev/null || echo "unknown")

# Assemble the golden transcript
mkdir -p "$OUTPUT_DIR"

SCENARIO=$(echo "$RR_JSON" | python3 -c "
import json, sys
r = json.load(sys.stdin)
ns = r.get('status',{}).get('remediationTarget',{}).get('namespace','')
if not ns:
    ns = r.get('status',{}).get('signalTarget',{}).get('namespace','')
print(ns.replace('demo-', '') if ns.startswith('demo-') else (ns or 'unknown'))
" 2>/dev/null || echo "unknown")

SIGNAL_NAME=$(echo "$AA_JSON" | python3 -c "
import json, sys
aa = json.load(sys.stdin)
print(aa.get('spec',{}).get('analysisRequest',{}).get('signalContext',{}).get('signalName','unknown'))
")

OUTFILE="${OUTPUT_DIR}/${SCENARIO}-${SIGNAL_NAME,,}.json"

python3 -c "
import json, sys
from datetime import datetime

aa = json.loads(sys.argv[1])
tool_data = json.loads(sys.argv[2])
ea_scores = json.loads(sys.argv[3])

transcript = {
    'scenario': sys.argv[4],
    'signalName': sys.argv[5],
    'kubernautVersion': sys.argv[6],
    'capturedAt': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'remediationRequest': {
        'name': sys.argv[7],
        'phase': sys.argv[8],
        'outcome': sys.argv[9],
    },
    'analysis': aa,
    'hapiDialog': tool_data,
    'effectivenessAssessment': ea_scores,
}
print(json.dumps(transcript, indent=2))
" \
    "$AA_STRUCTURED" \
    "$TOOL_CALLS" \
    "$EA_SCORES" \
    "$SCENARIO" \
    "$SIGNAL_NAME" \
    "$CHART_VERSION" \
    "$RR_NAME" \
    "$RR_PHASE" \
    "$RR_OUTCOME" \
    > "$OUTFILE"

echo ""
echo "==> Golden transcript saved to: $OUTFILE"
echo "  Scenario:  $SCENARIO"
echo "  Signal:    $SIGNAL_NAME"
echo "  RR:        $RR_NAME ($RR_PHASE / $RR_OUTCOME)"
echo "  Tool calls captured: $(echo "$TOOL_CALLS" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('toolCalls',[])))")"
echo "  AI messages captured: $(echo "$TOOL_CALLS" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('aiMessages',[])))")"
