#!/usr/bin/env python3
"""
Extract golden transcripts from the Kubernaut audit-events DB.
Produces one JSON file per scenario in golden-transcripts/.

Usage: KUBECONFIG=~/.kube/kubernaut-demo-config python3 scripts/capture-golden-transcripts.py
"""
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "golden-transcripts"
OUT_DIR.mkdir(exist_ok=True)

PLATFORM_NS = "kubernaut-system"
PARTITION = "audit_events_2026_04"

NS_MAP = {
    "demo-gitops": "gitops-drift",
    "demo-team-alpha": "concurrent-cross-namespace",
    "demo-team-beta": "concurrent-cross-namespace-beta",
    "demo-crashloop-helm": "crashloop-helm",
    "demo-alert-storm": "duplicate-alert-suppression",
    "demo-node": "node-notready",
    "demo-resource-contention": "resource-contention",
    "demo-statefulset": "statefulset-pvc-failure",
    "demo-cert-failure": "cert-failure",
    "demo-mesh-failure": "mesh-routing-failure",
    "demo-crashloop": "crashloop",
    "demo-rollout": "stuck-rollout",
    "demo-taint": "pending-taint",
    "demo-pdb": "pdb-deadlock",
    "demo-hpa": "hpa-maxed",
    "demo-memory-leak": "memory-leak",
    "demo-memory-escalation": "memory-escalation",
    "demo-netpol-2": "network-policy-block",
    "demo-autoscale": "autoscale",
    "demo-slo": "slo-burn",
    "demo-orphaned-pvc": "orphaned-pvc-no-action",
    "demo-quota": "resource-quota-exhaustion",
}


def find_pg_pod() -> str:
    result = subprocess.run(
        ["kubectl", "get", "pods", "-n", PLATFORM_NS, "--no-headers",
         "-o", "custom-columns=NAME:.metadata.name"],
        capture_output=True, text=True,
    )
    for line in result.stdout.strip().splitlines():
        if "postgresql" in line:
            return f"pod/{line.strip()}"
    sys.exit("ERROR: postgresql pod not found")


def psql(pg_pod: str, query: str) -> str:
    result = subprocess.run(
        ["kubectl", "exec", "-n", PLATFORM_NS, pg_pod, "--",
         "psql", "-U", "slm_user", "-d", "action_history", "-t", "-A", "-c", query],
        capture_output=True, text=True,
    )
    return result.stdout.strip()


def psql_json(pg_pod: str, query: str):
    raw = psql(pg_pod, query)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def build_workflow_id_map() -> dict[str, str]:
    """Map RemediationWorkflow status.workflowId to metadata.name."""
    result = subprocess.run(
        ["kubectl", "get", "remediationworkflows", "-n", PLATFORM_NS,
         "-o", "custom-columns=NAME:.metadata.name,WID:.status.workflowId", "--no-headers"],
        capture_output=True, text=True,
    )
    id_map = {}
    for line in result.stdout.strip().splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] != "<none>":
            id_map[parts[1]] = parts[0]
    return id_map


def main():
    pg_pod = find_pg_pod()
    print(f"Using PostgreSQL pod: {pg_pod}")
    print(f"Output directory: {OUT_DIR}\n")
    workflow_id_map = build_workflow_id_map()
    if workflow_id_map:
        print(f"Resolved {len(workflow_id_map)} workflow ID(s) -> name(s)")

    print("==> Discovering best run per scenario...")

    for ns, scenario in sorted(NS_MAP.items(), key=lambda x: x[1]):
        rr = psql(pg_pod, f"""
            SELECT e.correlation_id
            FROM {PARTITION} e
            JOIN {PARTITION} r ON r.event_data->>'incident_id' = e.correlation_id
                               AND r.event_type = 'aiagent.response.complete'
            LEFT JOIN LATERAL (
                SELECT event_data->>'to_phase' AS final_phase
                FROM {PARTITION}
                WHERE correlation_id = e.correlation_id
                  AND event_type = 'orchestrator.lifecycle.transitioned'
                ORDER BY event_timestamp DESC LIMIT 1
            ) t ON true
            WHERE e.event_type = 'gateway.signal.received'
              AND e.event_data->>'namespace' = '{ns}'
            ORDER BY (CASE
                        WHEN t.final_phase IN ('Completed','Blocked','Failed') THEN 3
                        WHEN t.final_phase IN ('Executing','Verifying') THEN 2
                        WHEN t.final_phase IS NOT NULL THEN 1
                        ELSE 0 END) DESC,
                     (r.event_data->'response_data'->>'confidence')::numeric DESC NULLS LAST,
                     e.event_timestamp DESC
            LIMIT 1;""")

        if not rr:
            print(f"  SKIP {scenario}: no incidents for {ns}")
            continue

        print(f"  {scenario} -> {rr}")

        # Full LLM response
        response = psql_json(pg_pod, f"""
            SELECT (event_data->'response_data')::text
            FROM {PARTITION}
            WHERE event_data->>'incident_id' = '{rr}'
              AND event_type = 'aiagent.response.complete'
            ORDER BY event_timestamp DESC LIMIT 1;""") or {}

        # Token stats
        token_stats = psql_json(pg_pod, f"""
            SELECT json_build_object(
              'totalTokens', SUM((event_data->>'tokens_used')::int),
              'llmTurns', COUNT(*)
            )::text
            FROM {PARTITION}
            WHERE event_data->>'incident_id' = '{rr}'
              AND event_type = 'aiagent.llm.response';""") or {}

        # Tool call count (excluding todo_write)
        tool_calls_str = psql(pg_pod, f"""
            SELECT COUNT(*)
            FROM {PARTITION}
            WHERE event_data->>'incident_id' = '{rr}'
              AND event_type = 'aiagent.llm.tool_call'
              AND event_data->>'tool_name' != 'todo_write';""")
        tool_calls_count = int(tool_calls_str) if tool_calls_str else 0
        token_stats["totalToolCalls"] = tool_calls_count

        # Tool call list
        tools = psql_json(pg_pod, f"""
            SELECT json_agg(json_build_object(
              'tool', event_data->>'tool_name',
              'index', (event_data->>'tool_call_index')::int
            ) ORDER BY event_timestamp)::text
            FROM {PARTITION}
            WHERE event_data->>'incident_id' = '{rr}'
              AND event_type = 'aiagent.llm.tool_call'
              AND event_data->>'tool_name' != 'todo_write';""") or []

        # Signal info
        signal = psql_json(pg_pod, f"""
            SELECT json_build_object(
              'signalName', event_data->>'signal_name',
              'namespace', event_data->>'namespace',
              'resourceKind', event_data->>'resource_kind',
              'resourceName', event_data->>'resource_name',
              'severity', event_data->>'severity'
            )::text
            FROM {PARTITION}
            WHERE correlation_id = '{rr}'
              AND event_type = 'gateway.signal.received'
            ORDER BY event_timestamp LIMIT 1;""") or {}

        # RR final phase
        rr_phase = psql(pg_pod, f"""
            SELECT event_data->>'to_phase'
            FROM {PARTITION}
            WHERE correlation_id = '{rr}'
              AND event_type = 'orchestrator.lifecycle.transitioned'
            ORDER BY event_timestamp DESC LIMIT 1;""") or "Unknown"

        # EA result
        ea_reason = psql(pg_pod, f"""
            SELECT event_data->>'reason'
            FROM {PARTITION}
            WHERE correlation_id = '{rr}'
              AND event_type = 'effectiveness.assessment.completed'
            ORDER BY event_timestamp DESC LIMIT 1;""") or ""

        # Approval required (did the RR transition through AwaitingApproval?)
        approval_phase = psql(pg_pod, f"""
            SELECT event_data->>'to_phase'
            FROM {PARTITION}
            WHERE correlation_id = '{rr}'
              AND event_type = 'orchestrator.lifecycle.transitioned'
              AND event_data->>'to_phase' = 'AwaitingApproval'
            LIMIT 1;""") or ""
        approval_required = approval_phase == "AwaitingApproval"

        # RR outcome
        rr_outcome_raw = psql(pg_pod, f"""
            SELECT event_outcome
            FROM {PARTITION}
            WHERE correlation_id = '{rr}'
              AND event_type = 'orchestrator.lifecycle.transitioned'
            ORDER BY event_timestamp DESC LIMIT 1;""") or ""

        # Determine outcome
        if ea_reason:
            outcome = "Remediated"
        elif "Blocked" in rr_phase:
            outcome = "ManualReviewRequired"
        elif "Failed" in rr_phase:
            outcome = "Failed"
        elif rr_phase in ("Executing", "Verifying"):
            outcome = "Remediated"
        else:
            outcome = rr_phase

        rca = response.get("rootCauseAnalysis", {})
        selected = response.get("selectedWorkflow")

        # Resolve workflow UUID to CRD name
        workflow_name = None
        if isinstance(selected, dict) and selected.get("workflowId"):
            workflow_name = workflow_id_map.get(selected["workflowId"])
        if workflow_name and isinstance(selected, dict):
            selected = {**selected, "workflowName": workflow_name}

        transcript = {
            "scenario": scenario,
            "incidentId": rr,
            "signal": signal,
            "analysis": {
                "phase": "Completed",
                "selectedWorkflow": selected if selected else None,
                "approvalRequired": approval_required,
                "needsHumanReview": response.get("needsHumanReview", False),
                "humanReviewReason": response.get("humanReviewReason"),
                "rootCauseAnalysis": rca,
            },
            "remediationRequest": {
                "outcome": outcome,
            },
            "kaResponse": {
                "confidence": response.get("confidence"),
                "analysis": response.get("analysis"),
            },
            "traceStats": token_stats,
            "toolCalls": tools,
        }

        out_path = OUT_DIR / f"{scenario}.json"
        with open(out_path, "w") as f:
            json.dump(transcript, f, indent=2)
        print(f"    -> {out_path}")

    print(f"\n==> Golden transcripts captured:")
    for f in sorted(OUT_DIR.glob("*.json")):
        with open(f) as fh:
            d = json.load(fh)
        conf = d.get("kaResponse", {}).get("confidence", "—")
        tokens = d.get("traceStats", {}).get("totalTokens", "—")
        calls = d.get("traceStats", {}).get("totalToolCalls", "—")
        print(f"  {d['scenario']:<35} conf={conf}  tokens={tokens}  tool_calls={calls}")


if __name__ == "__main__":
    main()
