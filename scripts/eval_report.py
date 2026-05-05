#!/usr/bin/env python3
"""
LLM Workflow Eval Scorer

Compares golden transcripts (produced by capture-eval.sh) against the eval
matrix (eval-matrix.json) and produces a per-scenario pass/fail report with
confidence calibration and token consumption analysis.

Usage:
    python3 scripts/eval_report.py [--transcripts DIR] [--matrix FILE] [--output FILE]
    python3 scripts/eval_report.py --compare v1.3.2 v1.4.0-rc5

Defaults:
    --transcripts  golden-transcripts/
    --matrix       scripts/eval-matrix.json
    --output       (stdout)

The --compare mode loads transcripts from golden-transcripts/archive/<VERSION>/
and produces a side-by-side diff table showing confidence, duration, token count,
turn count, tool call, and batching changes between two releases.

Exit codes:
    0  All scenarios passed (or compare mode completed)
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
        if raw.get("workflowName"):
            return raw["workflowName"]
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
            "expected": expected_val if not isinstance(expected_val, list) else " | ".join(str(v) for v in expected_val),
            "passed": ok,
        })
        if not ok:
            results["passed"] = False

    # 1. Workflow selection
    raw_workflow = analysis.get("selectedWorkflow")
    actual_workflow = _normalize_workflow(raw_workflow)
    expected_workflow = expected.get("expected_bundle")
    if isinstance(expected_workflow, list):
        ok = any(_match_workflow(actual_workflow, e) for e in expected_workflow)
        check("workflow_selected", actual_workflow,
              " | ".join(str(e) for e in expected_workflow), lambda a, e: ok)
    else:
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
    check("approval_required", actual_approval, expected_approval, match_outcome)

    # 5. Human review
    actual_review = analysis.get("needsHumanReview", False)
    expected_review = expected.get("needs_human_review", False)
    check("needs_human_review", actual_review, expected_review, match_outcome)

    if expected.get("human_review_reason"):
        actual_reason = analysis.get("humanReviewReason", "")
        expected_reason = expected.get("human_review_reason")
        check("human_review_reason", actual_reason, expected_reason, match_outcome)

    # 6. Target kind
    rca = analysis.get("rootCauseAnalysis") or {}
    actual_kind = rca.get("remediationTarget", {}).get("kind", "")
    if not actual_kind:
        target = analysis.get("signal", {}).get("targetResource") or {}
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


def _extract_trace_metrics(transcript: dict) -> dict:
    """Extract timing, token, and tool-call metrics from a transcript's llmTrace."""
    trace = transcript.get("llmTrace", [])
    stats = transcript.get("traceStats", {})
    metrics: dict[str, Any] = {
        "llm_turns": stats.get("llmTurns", 0),
        "tool_calls": stats.get("totalToolCalls", 0),
        "completion_tokens": stats.get("totalTokens", 0),
        "prompt_tokens": 0,
        "duration_s": None,
        "max_tools_per_turn": 0,
        "model": stats.get("model", ""),
    }
    if not trace:
        return metrics

    from datetime import datetime

    timestamps = []
    prompt_total = 0
    max_tc = 0
    for e in trace:
        ts_str = e.get("event_timestamp", "")
        if ts_str:
            try:
                timestamps.append(datetime.fromisoformat(ts_str))
            except ValueError:
                pass
        if e.get("event_type") == "aiagent.llm.request":
            pl = e.get("prompt_length")
            if pl:
                prompt_total += int(pl)
        if e.get("event_type") == "aiagent.llm.response":
            tc = e.get("tool_call_count")
            if tc:
                max_tc = max(max_tc, int(tc))

    metrics["prompt_tokens"] = prompt_total
    metrics["max_tools_per_turn"] = max_tc
    if len(timestamps) >= 2:
        metrics["duration_s"] = round((max(timestamps) - min(timestamps)).total_seconds(), 1)
    return metrics


def _fmt_delta(new_val, old_val, fmt=".0f", lower_is_better=False):
    """Format a value with a delta indicator."""
    if new_val is None or old_val is None:
        return "—"
    delta = new_val - old_val
    if delta == 0:
        return f"{new_val:{fmt}}"
    sign = "+" if delta > 0 else ""
    indicator = ""
    if lower_is_better:
        indicator = " ^" if delta < 0 else " v" if delta > 0 else ""
    else:
        indicator = " ^" if delta > 0 else " v" if delta < 0 else ""
    return f"{new_val:{fmt}} ({sign}{delta:{fmt}}{indicator})"


def compare_versions(dir_old: str, dir_new: str, output_file: str | None):
    """Compare transcripts from two archived versions."""
    old_transcripts = load_transcripts(dir_old)
    new_transcripts = load_transcripts(dir_new)

    def _best_per_scenario(transcripts: list[dict]) -> dict[str, dict]:
        """Keep the most complete transcript per scenario (prefer schema_version=1 with llmTrace)."""
        by_scenario: dict[str, dict] = {}
        for t in transcripts:
            s = t.get("scenario", "unknown")
            existing = by_scenario.get(s)
            if existing is None:
                by_scenario[s] = t
            else:
                new_has_trace = bool(t.get("llmTrace"))
                old_has_trace = bool(existing.get("llmTrace"))
                if new_has_trace and not old_has_trace:
                    by_scenario[s] = t
                elif new_has_trace and old_has_trace:
                    if len(t.get("llmTrace", [])) > len(existing.get("llmTrace", [])):
                        by_scenario[s] = t
        return by_scenario

    old_by_scenario = _best_per_scenario(old_transcripts)
    new_by_scenario = _best_per_scenario(new_transcripts)

    all_scenarios = sorted(set(old_by_scenario) | set(new_by_scenario))

    v_old = Path(dir_old).name
    v_new = Path(dir_new).name

    lines = []
    lines.append("=" * 100)
    lines.append(f"GOLDEN TRANSCRIPT COMPARISON: {v_old} -> {v_new}")
    lines.append("=" * 100)
    lines.append("")

    hdr = (f"{'Scenario':<30} {'Confidence':>18} {'Duration (s)':>18} "
           f"{'Tokens (comp)':>18} {'Turns':>10} {'Tools':>10} {'MaxTC/Turn':>10}")
    lines.append(hdr)
    lines.append("-" * 100)

    regressions = []
    improvements = []

    for scenario in all_scenarios:
        old_t = old_by_scenario.get(scenario)
        new_t = new_by_scenario.get(scenario)

        if not old_t:
            lines.append(f"{scenario:<30} {'(new)':>18}")
            continue
        if not new_t:
            lines.append(f"{scenario:<30} {'(missing)':>18}")
            continue

        old_m = _extract_trace_metrics(old_t)
        new_m = _extract_trace_metrics(new_t)

        old_conf = None
        new_conf = None
        for t, target in [(old_t, "old"), (new_t, "new")]:
            rca = t.get("analysis", {}).get("rootCauseAnalysis") or {}
            c = rca.get("confidence")
            if c is None:
                sw = t.get("analysis", {}).get("selectedWorkflow")
                if isinstance(sw, dict):
                    c = sw.get("confidence")
            if c is None:
                ka = t.get("kaResponse") or {}
                if isinstance(ka, str):
                    try:
                        ka = json.loads(ka)
                    except (json.JSONDecodeError, TypeError):
                        ka = {}
                c = ka.get("confidence")
            if c is not None:
                c = float(c)
            if target == "old":
                old_conf = c
            else:
                new_conf = c

        conf_str = _fmt_delta(new_conf, old_conf, ".2f", lower_is_better=False)
        dur_str = _fmt_delta(new_m["duration_s"], old_m["duration_s"], ".0f", lower_is_better=True)
        tok_str = _fmt_delta(new_m["completion_tokens"], old_m["completion_tokens"], ".0f", lower_is_better=True)
        turns_str = _fmt_delta(new_m["llm_turns"], old_m["llm_turns"], ".0f", lower_is_better=True)
        tools_str = _fmt_delta(new_m["tool_calls"], old_m["tool_calls"], ".0f", lower_is_better=True)
        maxtc_str = _fmt_delta(new_m["max_tools_per_turn"], old_m["max_tools_per_turn"], ".0f", lower_is_better=False)

        lines.append(f"{scenario:<30} {conf_str:>18} {dur_str:>18} {tok_str:>18} "
                     f"{turns_str:>10} {tools_str:>10} {maxtc_str:>10}")

        if old_conf and new_conf and new_conf < old_conf - 0.05:
            regressions.append((scenario, old_conf, new_conf))
        if old_conf and new_conf and new_conf > old_conf + 0.02:
            improvements.append((scenario, old_conf, new_conf))

    lines.append("-" * 100)
    lines.append("")
    lines.append(f"Scenarios compared: {len(all_scenarios)}  "
                 f"In both: {len(set(old_by_scenario) & set(new_by_scenario))}  "
                 f"New: {len(set(new_by_scenario) - set(old_by_scenario))}  "
                 f"Removed: {len(set(old_by_scenario) - set(new_by_scenario))}")

    if improvements:
        lines.append("")
        lines.append("CONFIDENCE IMPROVEMENTS (> +0.02):")
        for s, o, n in improvements:
            lines.append(f"  {s}: {o:.2f} -> {n:.2f} (+{n-o:.2f})")

    if regressions:
        lines.append("")
        lines.append("CONFIDENCE REGRESSIONS (> -0.05):")
        for s, o, n in regressions:
            lines.append(f"  {s}: {o:.2f} -> {n:.2f} ({n-o:.2f})")

    lines.append("")
    lines.append("Legend: ^ = improved, v = regressed (relative to column metric)")
    lines.append("")

    report = "\n".join(lines)
    if output_file:
        with open(output_file, "w") as f:
            f.write(report)
        print(f"Comparison report written to {output_file}")
    else:
        print(report)


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
    parser.add_argument("--compare", nargs=2, metavar=("VERSION_OLD", "VERSION_NEW"),
                        help="Compare two archived versions (e.g. --compare v1.3.2 v1.4.0-rc5)")
    args = parser.parse_args()

    if args.compare:
        base = Path(args.transcripts) / "archive"
        dir_old = str(base / args.compare[0])
        dir_new = str(base / args.compare[1])
        if not Path(dir_old).is_dir():
            print(f"ERROR: archive directory not found: {dir_old}", file=sys.stderr)
            sys.exit(2)
        if not Path(dir_new).is_dir():
            print(f"ERROR: archive directory not found: {dir_new}", file=sys.stderr)
            sys.exit(2)
        compare_versions(dir_old, dir_new, args.output)
        sys.exit(0)

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
