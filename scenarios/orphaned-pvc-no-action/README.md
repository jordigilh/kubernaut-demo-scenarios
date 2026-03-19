# Scenario #122: Orphaned PVC — LLM Judgment & Human-in-the-Loop

## Overview

Orphaned PVCs from completed batch jobs trigger a `KubePersistentVolumeClaimOrphaned`
alert. The `cleanup-pvc-v1` workflow **is present** in the catalog — this scenario
deliberately tests the LLM's judgment when a technically matching workflow exists but
the situation may not warrant automated intervention.

The LLM's behavior is non-deterministic, yielding two valid outcomes:

| Path | LLM Decision | Warnings | Outcome |
|------|-------------|----------|---------|
| **A** | No workflow selected (`actionable: false`) | None | `NoActionRequired` — auto-completes |
| **B** | Selects `CleanupPVC` + warns "Alert not actionable — no remediation warranted" | `["Alert not actionable — no remediation warranted"]` | `AwaitingApproval` — human review gate |

Both paths are correct. Path A reflects pure LLM confidence that no action is needed.
Path B shows the LLM hedging — it identifies a matching workflow but raises a warning
that the situation is benign housekeeping. The warning-aware Rego policy
(`has_warnings`) catches this and forces human review, even in non-production
environments.

**Signal**: `KubePersistentVolumeClaimOrphaned` — >3 bound PVCs in namespace for >3 min
**Severity**: `warning` / root cause severity `low`

## Signal Flow

```
Batch jobs complete → PVCs remain (orphaned) → kube-state-metrics
→ Prometheus (count bound PVCs > 3 for 3m) → AlertManager
→ Gateway webhook → RR created → SP → AA (HAPI/LLM)
→ Path A: NoActionRequired (auto-complete)
→ Path B: CleanupPVC selected + warning → Rego has_warnings → AwaitingApproval
```

## Warning-Aware Rego Policy

The default shipping Rego policy defines a `has_warnings` helper but does not wire it
into any `require_approval` rule. This means Path B would auto-execute the `CleanupPVC`
workflow in non-production environments without human review — the warning is silently
ignored.

The fix adds one rule and one risk factor:

```rego
# LLM warnings indicate the analysis flagged potential concerns.
# Even in non-production environments, these warrant human review.
require_approval if {
    has_warnings
}

risk_factors contains {"score": 75, "reason": "LLM raised warnings — human review recommended"} if {
    has_warnings
}
```

With this rule:
- **Production namespaces**: approval already required by `is_production` (score 70);
  warnings raise the score to 75 so the reason reflects the warning, not just the
  environment.
- **Staging/dev namespaces**: approval now required when LLM raises warnings;
  without warnings, the pipeline auto-approves as before.

> **Issue**: [kubernaut#439](https://github.com/jordigilh/kubernaut/issues/439) tracks
> adding this rule to the default Helm chart Rego.

## LLM Analysis (Path B — observed)

The LLM selects `CleanupPVC` with 90% confidence but simultaneously warns:

> *"Alert not actionable — no remediation warranted"*

Root cause analysis:
- **Summary**: Orphaned PVCs from completed batch jobs consuming unnecessary storage
  resources. No impact on running workloads.
- **Severity**: `low`
- **Contributing factors**: Completed batch jobs, Missing automatic PVC cleanup,
  Independent PVC lifecycle

The `data-processor` deployment is healthy — the orphaned PVCs are leftover storage,
not a service-impacting issue.

## Staging vs Production

The scenario ships with three overlays:

| Overlay | Environment label | Approval trigger |
|---------|------------------|-----------------|
| `manifests/` (base) | `production` | `is_production` (always) |
| `overlays/ocp` | `production` | `is_production` (always) |
| `overlays/staging` | `staging` | `has_warnings` (only when LLM warns) |

The staging overlay isolates the warnings rule — if the LLM takes Path B, approval
is triggered solely by the warning, proving the Rego rule works independently of the
production environment guard.

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics |
| StorageClass | `standard` (Kind) or cluster default (OCP) |
| Workflow catalog | `cleanup-pvc-v1` present (shipped with demo content) |
| Rego policy | Warning-aware rule recommended (`has_warnings`) |

## Automated Run

```bash
./scenarios/orphaned-pvc-no-action/run.sh
```

Options:
- `--interactive` — pause at approval gate for manual approve/reject
- `--no-validate` — skip the automated validation pipeline

## Manual Step-by-Step

```bash
# 1. Deploy (use overlays/staging to test warnings rule in isolation)
kubectl apply -k scenarios/orphaned-pvc-no-action/overlays/staging  # or overlays/ocp

# 2. Wait for deployment
kubectl wait --for=condition=Available deploy/data-processor -n demo-orphaned-pvc --timeout=120s

# 3. Inject orphaned PVCs
PLATFORM=ocp bash scenarios/orphaned-pvc-no-action/inject-orphan-pvcs.sh

# 4. Wait for alert (~3 min for: duration)
# Platform Prometheus → AlertManager → gateway-webhook

# 5. Monitor pipeline
kubectl get rr -n kubernaut-system -w

# Path A: RR → Completed (NoActionRequired)
# Path B: RR → AwaitingApproval → reject/approve via RAR patch
```

## Cleanup

```bash
./scenarios/orphaned-pvc-no-action/cleanup.sh
```

## Pipeline Timeline (OCP observed)

### Path A — NoActionRequired

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy + inject PVCs | T+0:00 | — |
| Alert fires | T+4:00 | 3 min `for:` + scrape interval |
| RR created | T+4:05 | 5 s |
| AA completes | T+5:21 | ~76 s investigation |
| **RR → Completed** | **T+5:21** | **auto-completes** |

### Path B — AwaitingApproval

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy + inject PVCs | T+0:00 | — |
| Alert fires | T+3:55 | 3 min `for:` + scrape interval |
| RR created | T+4:00 | 5 s |
| AA completes | T+5:31 | ~91 s investigation (6 poll cycles) |
| Rego evaluates warnings | T+5:31 | `has_warnings` → `require_approval` |
| **RR → AwaitingApproval** | **T+5:31** | **human review gate** |
| RAR expires (if no action) | T+20:31 | 15 min timeout |

## BDD Specification

```gherkin
Feature: Orphaned PVC — LLM judgment with available workflow

  Background:
    Given a cluster with Kubernaut services and a real LLM backend
      And the "cleanup-pvc-v1" workflow is registered in the catalog
      And the warning-aware Rego policy (has_warnings) is active
      And the "data-processor" deployment is running in namespace "demo-orphaned-pvc"

  Scenario: Path A — LLM determines no action needed
    When 5 orphaned PVCs from simulated completed batch jobs are created
      And the KubePersistentVolumeClaimOrphaned alert fires (>3 bound PVCs for 3 min)
    Then the alert flows through Gateway → SP → AA (HAPI)
      And the LLM sets actionable to false with no warnings
      And AA outcome is WorkflowNotNeeded
      And RO marks the RR as Completed with outcome NoActionRequired
      And no WorkflowExecution CRD is created
      And all 5 orphaned PVCs remain in the namespace

  Scenario: Path B — LLM selects workflow but warns (human-in-the-loop)
    When 5 orphaned PVCs from simulated completed batch jobs are created
      And the KubePersistentVolumeClaimOrphaned alert fires (>3 bound PVCs for 3 min)
    Then the alert flows through Gateway → SP → AA (HAPI)
      And the LLM selects CleanupPVC with warnings ["Alert not actionable — no remediation warranted"]
      And Rego policy evaluates has_warnings → require_approval
      And approvalReason is "LLM raised warnings — human review recommended"
      And RR transitions to AwaitingApproval
      And a RemediationApprovalRequest is created
      And all 5 orphaned PVCs remain in the namespace (pending human decision)
```

## Acceptance Criteria

- [ ] 5 orphaned PVCs are created and bound successfully
- [ ] Alert fires after 3 minutes
- [ ] Path A: RR reaches `Completed` with outcome `NoActionRequired`, no WFE
- [ ] Path B: RR reaches `AwaitingApproval`, reason mentions "LLM raised warnings"
- [ ] Path B: `approvalReason` is **not** "Production environment" when using staging overlay
- [ ] Orphaned PVCs remain untouched regardless of path
- [ ] Both paths are valid — scenario passes if either outcome is observed
