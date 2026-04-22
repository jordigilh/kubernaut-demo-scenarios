#!/usr/bin/env python3
"""
LLM Workflow Eval Scorer

Compares golden transcripts (produced by capture-eval.sh) against the eval
matrix (eval-matrix.json) and produces a per-scenario pass/fail report with
confidence calibration and token consumption analysis.

Usage:
    python3 scripts/eval_report.py [--transcripts DIR] [--matrix FILE] [--output FILE]

Defaults:
    --transcripts  golden-transcripts/
    --matrix       scripts/eval-matrix.json
    --output       (stdout)

Exit codes:
    0  All scenarios passed
    1  One or more scenarios failed
    2  Usage / configuration error
"""
import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


def _normalize_workflow(raw: Any) -> str | None:
    """Extract a comparable workflow name from the AA selectedWorkflow field.

    The field may be None (escalation), a string, or a dict with
    executionBundle/workflowId/rationale etc.
    """
    if raw is None:
        return None
    if isinstance(raw, str):
        return raw
    if isinstance(raw, dict):
        bundle = raw.get("executionBundle", "")
        if "/" in bundle:
            image_part = bundle.rsplit("/", 1)[-1]
            image_name = image_part.split("@")[0].split(":")[0]
            return image_name
        return raw.get("workflowId", str(raw))
    return str(raw)


def _match_workflow(actual: str | None, expected: str | None) -> bool:
    """Compare workflow selection, handling image-name vs workflow-name."""
    if actual is None and expected is None:
        return True
    if actual is None or expected is None:
        return False
    if actual == expected:
        return True
    import re
    actual_base = re.sub(r'-job$', '', actual)
    expected_base = re.sub(r'-v\d+$', '', expected)
    return actual_base == expected_base


def load_matrix(path: str) -> dict:
    with open(path) as f:
        data = json.load(f)
    if data.get("schema_version") != 1:
        print(f"WARN: eval-matrix schema_version={data.get('schema_version')}, expected 1", file=sys.stderr)
    return data["scenarios"]


def load_transcripts(directory: str) -> list[dict]:
    transcripts = []
    p = Path(directory)
    if not p.is_dir():
        print(f"ERROR: transcript directory not found: {directory}", file=sys.stderr)
        sys.exit(2)
    for f in sorted(p.glob("*.json")):
        with open(f) as fh:
            try:
                t = json.load(fh)
                t["_file"] = str(f)
                transcripts.append(t)
            except json.JSONDecodeError as e:
                print(f"WARN: skipping {f}: {e}", file=sys.stderr)
    return transcripts


def validate_sync(matrix: dict, workflow_mappings_path: str | None) -> list[str]:
    """Check that eval-matrix scenarios align with workflow-mappings.sh."""
    warnings = []
    if not workflow_mappings_path or not os.path.exists(workflow_mappings_path):
        return warnings

    with open(workflow_mappings_path) as f:
        content = f.read()

    mapping_scenarios = set()
    for line in content.splitlines():
        line = line.strip().strip('"').strip("'")
        if ":" in line and not line.startswith("#") and not line.startswith("WORKFLOWS"):
            scenario = line.split(":")[0].strip()
            if scenario:
                mapping_scenarios.add(scenario)

    matrix_scenarios = set(matrix.keys())
    special_entries = {"memory-escalation-cycle2"}
    escalation_scenarios = {s for s in matrix_scenarios
                           if matrix[s].get("expected_bundle") is None}
    matrix_base = matrix_scenarios - special_entries - escalation_scenarios

    in_mappings_not_matrix = mapping_scenarios - matrix_base
    in_matrix_not_mappings = matrix_base - mapping_scenarios

    for s in sorted(in_mappings_not_matrix):
        warnings.append(f"workflow-mappings.sh has '{s}' but eval-matrix.json does not")
    for s in sorted(in_matrix_not_mappings):
        warnings.append(f"eval-matrix.json has '{s}' but workflow-mappings.sh does not")

    return warnings


def match_outcome(actual: str, expected: Any) -> bool:
    if isinstance(expected, list):
        return actual in expected
    return actual == expected


def score_scenario(transcript: dict, expected: dict) -> dict:
    """Score a single transcript against its expected entry."""
    results = {
        "scenario": transcript.get("scenario", "unknown"),
        "file": transcript.get("_file", ""),
        "checks": [],
        "passed": True,
        "confidence_actual": None,
        "confidence_expected": expected.get("confidence_expected"),
        "confidence_floor": expected.get("confidence_floor"),
        "confidence_delta": None,
        "tokens": transcript.get("traceStats", {}).get("totalTokens", 0),
        "llm_turns": transcript.get("traceStats", {}).get("llmTurns", 0),
        "tool_calls": transcript.get("traceStats", {}).get("totalToolCalls", 0),
    }

    analysis = transcript.get("analysis", {})

    def check(name: str, actual: Any, expected_val: Any, comparator=None):
        if comparator:
            ok = comparator(actual, expected_val)
        else:
            ok = actual == expected_val
        results["checks"].append({
            "name": name,
            "actual": actual,
            "expected": expected_val if not isinstance(expected_val, list) else " | ".join(expected_val),
            "passed": ok,
        })
        if not ok:
            results["passed"] = False

    # 1. Workflow selection
    raw_workflow = analysis.get("selectedWorkflow")
    actual_workflow = _normalize_workflow(raw_workflow)
    expected_workflow = expected.get("expected_bundle")
    check("workflow_selected", actual_workflow, expected_workflow, _match_workflow)

    # 2. RR outcome
    actual_outcome = transcript.get("remediationRequest", {}).get("outcome", "")
    expected_outcome = expected.get("expected_outcome")
    check("rr_outcome", actual_outcome, expected_outcome, match_outcome)

    # 3. AA phase
    actual_phase = analysis.get("phase", "")
    expected_phase = expected.get("expected_aa_phase")
    check("aa_phase", actual_phase, expected_phase)

    # 4. Approval
    actual_approval = analysis.get("approvalRequired", False)
    expected_approval = expected.get("approval_expected", False)
    check("approval_required", actual_approval, expected_approval)

    # 5. Human review
    actual_review = analysis.get("needsHumanReview", False)
    expected_review = expected.get("needs_human_review", False)
    check("needs_human_review", actual_review, expected_review)

    if expected.get("human_review_reason"):
        actual_reason = analysis.get("humanReviewReason", "")
        check("human_review_reason", actual_reason, expected.get("human_review_reason"))

    # 6. Target kind
    rca = analysis.get("rootCauseAnalysis") or {}
    actual_kind = rca.get("remediationTarget", {}).get("kind", "")
    if not actual_kind:
        target = analysis.get("signal", {}).get("targetResource", {})
        actual_kind = target.get("kind", "")
    expected_kind = expected.get("expected_target_kind", "")
    check("target_kind", actual_kind, expected_kind, match_outcome)

    # 7. Confidence calibration
    rca_obj = analysis.get("rootCauseAnalysis") or {}
    confidence_raw = rca_obj.get("confidence")
    if confidence_raw is None:
        ka_resp = transcript.get("kaResponse") or {}
        if isinstance(ka_resp, str):
            try:
                ka_resp = json.loads(ka_resp)
            except (json.JSONDecodeError, TypeError):
                ka_resp = {}
        confidence_raw = ka_resp.get("confidence")

    if confidence_raw is not None:
        try:
            confidence = float(confidence_raw)
        except (ValueError, TypeError):
            confidence = None
    else:
        confidence = None

    results["confidence_actual"] = confidence

    floor = expected.get("confidence_floor")
    if confidence is not None and floor is not None:
        results["confidence_delta"] = round(confidence - (expected.get("confidence_expected") or confidence), 3)
        if confidence < floor:
            results["checks"].append({
                "name": "confidence_floor",
                "actual": confidence,
                "expected": f">= {floor}",
                "passed": False,
            })
            results["passed"] = False
        else:
            results["checks"].append({
                "name": "confidence_floor",
                "actual": confidence,
                "expected": f">= {floor}",
                "passed": True,
            })

    return results


def find_scenario_key(scenario_name: str, matrix: dict) -> str | None:
    """Map a transcript scenario name to a matrix key."""
    if scenario_name in matrix:
        return scenario_name
    for suffix in ["-ns", ""]:
        candidate = scenario_name.rstrip(suffix) if suffix else scenario_name
        if candidate in matrix:
            return candidate
    normalized = scenario_name.replace("-", "").replace("_", "")
    for key in matrix:
        if key.replace("-", "").replace("_", "") == normalized:
            return key
    return None


def print_report(results: list[dict], sync_warnings: list[str], output_file: str | None):
    lines = []

    lines.append("=" * 80)
    lines.append("LLM WORKFLOW EVAL REPORT")
    lines.append("=" * 80)
    lines.append("")

    if sync_warnings:
        lines.append("SYNC WARNINGS (eval-matrix.json vs workflow-mappings.sh):")
        for w in sync_warnings:
            lines.append(f"  ! {w}")
        lines.append("")

    total = len(results)
    passed = sum(1 for r in results if r["passed"])
    failed = total - passed

    lines.append(f"Scenarios scored: {total}   Passed: {passed}   Failed: {failed}")
    lines.append("")

    # Per-scenario detail
    for r in results:
        status = "PASS" if r["passed"] else "FAIL"
        lines.append(f"--- {r['scenario']} [{status}] ---")
        lines.append(f"    File: {r['file']}")
        for c in r["checks"]:
            mark = "OK" if c["passed"] else "XX"
            lines.append(f"    [{mark}] {c['name']}: actual={c['actual']}  expected={c['expected']}")
        if r["confidence_actual"] is not None:
            lines.append(f"    Confidence: {r['confidence_actual']} (expected {r['confidence_expected']}, "
                         f"floor {r['confidence_floor']}, delta {r['confidence_delta']})")
        lines.append(f"    Tokens: {r['tokens']}  LLM turns: {r['llm_turns']}  Tool calls: {r['tool_calls']}")
        lines.append("")

    # Summary table
    lines.append("-" * 80)
    lines.append(f"{'Scenario':<35} {'Status':<6} {'Workflow':<28} {'Conf':>5} {'Tokens':>7} {'Turns':>5}")
    lines.append("-" * 80)
    for r in results:
        status = "PASS" if r["passed"] else "FAIL"
        wf = "—"
        for c in r["checks"]:
            if c["name"] == "workflow_selected":
                wf = str(c["actual"]) if c["actual"] else "(none)"
                break
        conf = f"{r['confidence_actual']:.2f}" if r['confidence_actual'] is not None else "—"
        lines.append(f"{r['scenario']:<35} {status:<6} {wf:<28} {conf:>5} {r['tokens']:>7} {r['llm_turns']:>5}")
    lines.append("-" * 80)
    lines.append(f"{'TOTAL':<35} {f'{passed}/{total}':>6}")
    lines.append("")

    # Confidence regression summary
    regressions = [r for r in results if r.get("confidence_delta") is not None and r["confidence_delta"] < -0.10]
    if regressions:
        lines.append("CONFIDENCE REGRESSIONS (delta < -0.10 vs baseline):")
        for r in regressions:
            lines.append(f"  {r['scenario']}: {r['confidence_actual']} (expected {r['confidence_expected']}, "
                         f"delta {r['confidence_delta']})")
        lines.append("")

    # Token consumption summary
    if results:
        total_tokens = sum(r["tokens"] for r in results)
        avg_tokens = total_tokens / len(results)
        max_r = max(results, key=lambda r: r["tokens"])
        lines.append(f"Token consumption: total={total_tokens}  avg={avg_tokens:.0f}  "
                     f"max={max_r['tokens']} ({max_r['scenario']})")
        lines.append("")

    report = "\n".join(lines)

    if output_file:
        with open(output_file, "w") as f:
            f.write(report)
        print(f"Report written to {output_file}")
    else:
        print(report)

    return failed


def main():
    parser = argparse.ArgumentParser(description="LLM Workflow Eval Scorer")
    parser.add_argument("--transcripts", default="golden-transcripts/",
                        help="Directory containing golden transcript JSON files")
    parser.add_argument("--matrix", default="scripts/eval-matrix.json",
                        help="Path to eval-matrix.json")
    parser.add_argument("--output", default=None,
                        help="Output file (default: stdout)")
    parser.add_argument("--workflow-mappings", default="scripts/workflow-mappings.sh",
                        help="Path to workflow-mappings.sh for sync validation")
    args = parser.parse_args()

    matrix = load_matrix(args.matrix)
    transcripts = load_transcripts(args.transcripts)
    sync_warnings = validate_sync(matrix, args.workflow_mappings)

    if not transcripts:
        print("ERROR: No transcripts found in " + args.transcripts, file=sys.stderr)
        sys.exit(2)

    results = []
    unmatched = []

    for t in transcripts:
        scenario = t.get("scenario", "unknown")
        key = find_scenario_key(scenario, matrix)
        if key is None:
            unmatched.append(scenario)
            continue
        results.append(score_scenario(t, matrix[key]))

    if unmatched:
        print(f"WARN: {len(unmatched)} transcript(s) had no matrix entry: {', '.join(unmatched)}", file=sys.stderr)

    failed = print_report(results, sync_warnings, args.output)
    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    main()
