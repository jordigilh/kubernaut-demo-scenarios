#!/usr/bin/env bash
# Extract golden transcripts from the Kubernaut audit-events DB.
# Produces one JSON file per scenario in golden-transcripts/.
#
# Usage: KUBECONFIG=~/.kube/kubernaut-demo-config ./scripts/capture-golden-transcripts.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_ROOT}/golden-transcripts"
mkdir -p "${OUT_DIR}"

PG_POD=$(kubectl get pods -n kubernaut-system -l app.kubernetes.io/name=postgresql -o name 2>/dev/null | head -1)
if [ -z "$PG_POD" ]; then
  PG_POD="pod/$(kubectl get pods -n kubernaut-system --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep postgresql | head -1)"
fi

PARTITION="audit_events_2026_04"

_psql() {
  kubectl exec -n kubernaut-system "${PG_POD}" -- \
    psql -U kubernaut -d kubernaut -t -A -c "$1" 2>/dev/null
}

# Namespace-to-scenario mapping
declare -A NS_MAP=(
  [demo-gitops]=gitops-drift
  [demo-team-alpha]=concurrent-cross-namespace
  [demo-team-beta]=concurrent-cross-namespace-beta
  [demo-crashloop-helm]=crashloop-helm
  [demo-alert-storm]=duplicate-alert-suppression
  [demo-node]=node-notready
  [demo-resource-contention]=resource-contention
  [demo-statefulset]=statefulset-pvc-failure
  [demo-cert-failure]=cert-failure
  [demo-mesh-failure]=mesh-routing-failure
)

echo "==> Discovering best run per scenario..."

# For each namespace, find the best incident (highest confidence with a workflow selected)
for ns in "${!NS_MAP[@]}"; do
  scenario="${NS_MAP[$ns]}"

  rr=$(_psql "
    SELECT e.correlation_id
    FROM ${PARTITION} e
    JOIN ${PARTITION} r ON r.event_data->>'incident_id' = e.correlation_id
                       AND r.event_type = 'aiagent.response.complete'
    WHERE e.event_type = 'gateway.signal.received'
      AND e.event_data->>'namespace' = '${ns}'
    ORDER BY (r.event_data->'response_data'->>'confidence')::numeric DESC NULLS LAST,
             e.event_timestamp DESC
    LIMIT 1;")

  if [ -z "$rr" ]; then
    echo "  SKIP ${scenario}: no incidents found for namespace ${ns}"
    continue
  fi

  echo "  ${scenario} -> ${rr}"

  # Full LLM response
  response_json=$(_psql "
    SELECT (event_data->'response_data')::text
    FROM ${PARTITION}
    WHERE event_data->>'incident_id' = '${rr}'
      AND event_type = 'aiagent.response.complete'
    ORDER BY event_timestamp DESC LIMIT 1;")

  # Token stats
  token_stats=$(_psql "
    SELECT json_build_object(
      'totalTokens', SUM((event_data->>'tokens_used')::int),
      'llmTurns', COUNT(*)
    )::text
    FROM ${PARTITION}
    WHERE event_data->>'incident_id' = '${rr}'
      AND event_type = 'aiagent.llm.response';")

  # Tool call count (excluding todo_write)
  tool_calls=$(_psql "
    SELECT COUNT(*)
    FROM ${PARTITION}
    WHERE event_data->>'incident_id' = '${rr}'
      AND event_type = 'aiagent.llm.tool_call'
      AND event_data->>'tool_name' != 'todo_write';")

  # Tool call list
  tool_list=$(_psql "
    SELECT json_agg(json_build_object(
      'tool', event_data->>'tool_name',
      'index', (event_data->>'tool_call_index')::int
    ) ORDER BY event_timestamp)::text
    FROM ${PARTITION}
    WHERE event_data->>'incident_id' = '${rr}'
      AND event_type = 'aiagent.llm.tool_call'
      AND event_data->>'tool_name' != 'todo_write';")

  # Signal info
  signal_json=$(_psql "
    SELECT json_build_object(
      'signalName', event_data->>'signal_name',
      'namespace', event_data->>'namespace',
      'resourceKind', event_data->>'resource_kind',
      'resourceName', event_data->>'resource_name',
      'severity', event_data->>'severity'
    )::text
    FROM ${PARTITION}
    WHERE correlation_id = '${rr}'
      AND event_type = 'gateway.signal.received'
    ORDER BY event_timestamp LIMIT 1;")

  # RR outcome from orchestrator events
  rr_outcome=$(_psql "
    SELECT event_data->>'to_phase'
    FROM ${PARTITION}
    WHERE correlation_id = '${rr}'
      AND event_type = 'orchestrator.lifecycle.transitioned'
    ORDER BY event_timestamp DESC LIMIT 1;") || true

  # EA result
  ea_outcome=$(_psql "
    SELECT event_data->>'reason'
    FROM ${PARTITION}
    WHERE correlation_id = '${rr}'
      AND event_type = 'effectiveness.assessment.completed'
    ORDER BY event_timestamp DESC LIMIT 1;") || true

  # Assemble golden transcript JSON
  python3 -c "
import json, sys

scenario = '${scenario}'
rr_id = '${rr}'
rr_outcome = '${rr_outcome}'.strip() or 'Unknown'
ea_outcome = '${ea_outcome}'.strip() or None
tool_calls_count = int('${tool_calls}'.strip() or '0')

response = json.loads('''${response_json}''') if '''${response_json}'''.strip() else {}
token_stats = json.loads('''${token_stats}''') if '''${token_stats}'''.strip() else {}
signal = json.loads('''${signal_json}''') if '''${signal_json}'''.strip() else {}
tools = json.loads('''${tool_list}''') if '''${tool_list}'''.strip() else []

token_stats['totalToolCalls'] = tool_calls_count

rca = response.get('rootCauseAnalysis', {})
selected = response.get('selectedWorkflow', {})

transcript = {
    'scenario': scenario,
    'incidentId': rr_id,
    'signal': signal,
    'analysis': {
        'phase': 'Completed',
        'selectedWorkflow': selected if selected else None,
        'approvalRequired': response.get('needsHumanReview', False) == False and bool(selected),
        'needsHumanReview': response.get('needsHumanReview', False),
        'humanReviewReason': response.get('humanReviewReason'),
        'rootCauseAnalysis': rca,
    },
    'remediationRequest': {
        'outcome': 'Remediated' if ea_outcome else rr_outcome,
    },
    'kaResponse': {
        'confidence': response.get('confidence'),
        'analysis': response.get('analysis'),
    },
    'traceStats': token_stats,
    'toolCalls': tools,
}

print(json.dumps(transcript, indent=2))
" > "${OUT_DIR}/${scenario}.json"

  echo "    -> ${OUT_DIR}/${scenario}.json"
done

echo ""
echo "==> Golden transcripts captured:"
ls -1 "${OUT_DIR}"/*.json 2>/dev/null | while read f; do
  scenario=$(python3 -c "import json; print(json.load(open('$f'))['scenario'])")
  conf=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('kaResponse',{}).get('confidence','—'))")
  tokens=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('traceStats',{}).get('totalTokens','—'))")
  echo "  ${scenario}: confidence=${conf}  tokens=${tokens}"
done
