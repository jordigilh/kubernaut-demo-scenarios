# Concurrent Cross-Namespace Demo

## Quick Start

```bash
./run.sh
```

## What It Demonstrates

Same incident (CrashLoopBackOff), different risk tolerances and environments → different workflow selection and approval flows.

- **Team Alpha** (staging, high risk tolerance): Auto-approved, gets `restart-pods-v1` — simpler, less disruptive.
- **Team Beta** (production, low risk tolerance): Requires manual approval, gets `crashloop-rollback-v1` — more thorough, safer.

## Key Mechanism

1. **SignalProcessing Rego policy** maps namespace label `kubernaut.ai/risk-tolerance` into customLabels (`risk_tolerance`).
2. **DataStorage** scores workflows by customLabels match.
3. **LLM** selects the workflow that aligns with the team's risk tolerance.
4. **Approval Rego policy** auto-approves staging environments (`kubernaut.ai/environment=staging`) and requires manual approval for production (`kubernaut.ai/environment=production`).

## Pipeline Path (Parallel)

| Team  | Environment | Approval | Path |
|-------|-------------|----------|------|
| Alpha | staging     | auto     | Alert → SP (risk_tolerance=high) → AA → auto-approve → restart-pods-v1 |
| Beta  | production  | manual   | Alert → SP (risk_tolerance=low) → AA → manual approve → crashloop-rollback-v1 |

## Business Requirement

- **BR-SP-102**: Custom labels enrichment for workflow scoring

## Issue

- **#172**: Concurrent cross-namespace scenario

## Cleanup

```bash
./scenarios/concurrent-cross-namespace/cleanup.sh
```

## Note

Custom labels Rego policies use `package signalprocessing.customlabels` with a `labels` rule. The engine queries `data.signalprocessing.customlabels.labels`, keeping custom labels in a dedicated package separate from the 5 mandatory label classifiers.
