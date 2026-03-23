# Scenario #122: Orphaned PVC — LLM Judgment & Human-in-the-Loop

## Overview

Orphaned PVCs from completed batch jobs trigger a `KubePersistentVolumeClaimOrphaned`
alert. The `cleanup-pvc-v1` workflow **is present** in the catalog — this scenario
deliberately tests the LLM's judgment when a technically matching workflow exists but
the situation may not warrant automated intervention.

The LLM's behavior is non-deterministic, yielding three valid outcomes:

| Path | LLM Decision | Warnings | Outcome |
|------|-------------|----------|---------|
| **A** | No workflow selected (`actionable: false`) | None | `NoActionRequired` — auto-completes |
| **B** | Selects `CleanupPVC` + warns "no remediation warranted" | `["Alert not actionable — no remediation warranted"]` | `AwaitingApproval` — human review gate |
| **C** | Selects `CleanupPVC`, no warnings | None | `Remediated` — PVCs cleaned up |

All three paths are correct. Path A reflects pure LLM confidence that no action is
needed. Path B shows the LLM hedging — it identifies a matching workflow but raises a
warning that the situation is benign housekeeping; the warning-aware Rego policy
(`has_warnings`) catches this and forces human review. Path C shows the LLM confidently
selecting the cleanup workflow — orphaned PVCs from completed batch jobs are a valid
cleanup target, and the LLM proceeds without hesitation.

**Signal**: `KubePersistentVolumeClaimOrphaned` — >3 bound PVCs in namespace for >3 min
**Severity**: `warning` / root cause severity `low`

## Signal Flow

```
Batch jobs complete → PVCs remain (orphaned) → kube-state-metrics
→ Prometheus (count bound PVCs > 3 for 3m) → AlertManager
→ Gateway webhook → RR created → SP → AA (HAPI/LLM)
→ Path A: NoActionRequired (auto-complete)
→ Path B: CleanupPVC selected + warning → Rego llm_warns_no_remediation → AwaitingApproval
→ Path C: CleanupPVC selected, no warnings → WFE → Remediated
```

## Warning-Aware Rego Policy

The default shipping Rego policy only gates on `is_production`. It does not inspect
`input.warnings`. This means Path B would auto-execute the `CleanupPVC` workflow in
non-production environments without human review — the LLM's warning is silently
ignored.

The custom `rego/approval-warnings.rego` adds targeted and catch-all rules:

```rego
llm_warns_no_remediation if {
    some w in input.warnings
    contains(w, "no remediation warranted")
}

require_approval if { llm_warns_no_remediation }
require_approval if { has_warnings }

risk_factors contains {"score": 80, "reason": "LLM warning: no remediation warranted"} if {
    llm_warns_no_remediation
}
risk_factors contains {"score": 75, "reason": "LLM raised warnings — human review recommended"} if {
    has_warnings
    not llm_warns_no_remediation
}
```

With these rules:
- **Staging/dev namespaces**: approval required only when LLM raises warnings;
  without warnings, the pipeline auto-approves as before.
- **"no remediation warranted" signal** (score 80): the specific warning string
  from the LLM gets the highest score and a targeted reason.
- **Production namespaces**: approval already required by `is_production` (score 40);
  warnings raise the score to 80 so the reason reflects the warning, not the
  environment.

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

## Why Staging?

The scenario runs in a **staging** namespace to isolate the `has_warnings` approval
mechanism. In a production namespace, the default `is_production` rule would always
require approval regardless of warnings — you'd never know whether approval was
triggered by the environment or by the LLM warning.

In staging, the default policy auto-approves everything. Only the custom
`llm_warns_no_remediation` rule can trigger the approval gate, proving the Rego catches
LLM ambivalence independently of the environment guard.

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics |
| StorageClass | `standard` (Kind) or cluster default (OCP) |
| Workflow catalog | `cleanup-pvc-v1` present (shipped with demo content) |
| Rego policy | Warning-aware rule (`llm_warns_no_remediation`) — applied by `run.sh` |

## Automated Run

```bash
./scenarios/orphaned-pvc-no-action/run.sh
```

Options:
- `--interactive` — pause at approval gate for manual approve/reject
- `--no-validate` — skip the automated validation pipeline

## Manual Step-by-Step

```bash
# 1. Deploy (base manifests use staging; overlays/ocp for OpenShift)
kubectl apply -k scenarios/orphaned-pvc-no-action/manifests  # or overlays/ocp

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
# Path C: RR → Completed (Remediated) — PVCs cleaned up
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
| Rego evaluates warnings | T+5:31 | `llm_warns_no_remediation` → `require_approval` |
| **RR → AwaitingApproval** | **T+5:31** | **human review gate** |
| RAR expires (if no action) | T+20:31 | 15 min timeout |

## BDD Specification

```gherkin
Feature: Orphaned PVC — LLM judgment with available workflow

  Background:
    Given a cluster with Kubernaut services and a real LLM backend
      And the "cleanup-pvc-v1" workflow is registered in the catalog
      And the warning-aware Rego policy (llm_warns_no_remediation) is active
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
      And Rego policy evaluates llm_warns_no_remediation → require_approval
      And approvalReason is "LLM warning: no remediation warranted"
      And RR transitions to AwaitingApproval
      And a RemediationApprovalRequest is created
      And all 5 orphaned PVCs remain in the namespace (pending human decision)

  Scenario: Path C — LLM selects workflow without warnings (automated cleanup)
    When 5 orphaned PVCs from simulated completed batch jobs are created
      And the KubePersistentVolumeClaimOrphaned alert fires (>3 bound PVCs for 3 min)
    Then the alert flows through Gateway → SP → AA (HAPI)
      And the LLM selects CleanupPVC with no warnings
      And a WorkflowExecution is created and completes
      And RO marks the RR as Completed with outcome Remediated
      And the 5 orphaned PVCs are deleted by the cleanup workflow
```

## Acceptance Criteria

- [ ] 5 orphaned PVCs are created and bound successfully
- [ ] Alert fires after 3 minutes
- [ ] Path A: RR reaches `Completed` with outcome `NoActionRequired`, no WFE, PVCs remain
- [ ] Path B: RR reaches `AwaitingApproval`, reason mentions "no remediation warranted"
- [ ] Path B: `approvalReason` is "LLM warning: no remediation warranted", not "Production environment"
- [ ] Path C: RR reaches `Completed` with outcome `Remediated`, WFE completes, PVCs deleted
- [ ] All three paths are valid — scenario passes if any outcome is observed
