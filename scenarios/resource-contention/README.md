# Scenario #231: Resource Contention — External Actor Interference Detection

## Overview

Demonstrates Kubernaut's ability to detect **external actor interference** — when a
GitOps controller, another operator, or manual intervention repeatedly reverts
Kubernaut's remediation, the platform detects the ineffective remediation chain via
DataStorage hash analysis (`spec_drift`) and escalates to human review.

The scenario deploys a workload with insufficient memory limits (64 Mi for a 64 MB
stress allocator), causing OOMKills. Kubernaut remediates by increasing memory limits,
but a background "external actor" script continuously reverts the limits back. After
repeated failures, the Remediation Orchestrator (RO) detects the pattern.

**Signal**: `ContainerOOMKilling` — container OOMKilled for >30 s
**Root cause**: Memory limit (64 Mi) too restrictive for workload allocating 64 MB
**Remediation**: `IncreaseMemoryLimits` (doubles to 128 Mi)
**Interference**: External actor reverts limits to 64 Mi after each remediation

## Signal Flow

```
Stress allocator (64 MB) > memory limit (64 Mi) → OOMKill
→ kube-state-metrics (last_terminated_reason=OOMKilled)
→ Prometheus (for: 30s) → AlertManager → Gateway webhook
→ RR → SP → AA → WFE (IncreaseMemoryLimits 64→128Mi) → EA (healthScore: 1)
→ External actor reverts 128→64Mi → OOMKill recurs
→ Cycle 2: same fix, same revert → EA detects spec_drift
→ Cycle 3: RO detects ineffective chain → ManualReviewRequired
```

## LLM Analysis (OCP observed — Cycle 1)

Root cause analysis:

- **Summary**: Container memory limit (64 Mi) is too restrictive for stress application
  that allocates 64 MB, causing immediate OOM kills with no headroom for runtime
  overhead.
- **Severity**: `high`
- **Contributing factors**:
  - Memory limit exactly matches application allocation with no overhead buffer
  - Stress tool configured to allocate 64 MB against 64 Mi limit
  - No memory headroom for container runtime
- **Workflow**: `IncreaseMemoryLimits` (confidence 0.95)
  - `MEMORY_INCREASE_FACTOR: 2` (doubles to 128 Mi)
- **Effectiveness**: healthScore 1.0 (spec hashes match post-remediation)

## External Actor Behavior

The `scripts/external-actor.sh` simulates a GitOps controller:

1. Waits for the first RR to reach a terminal state (ensures clean first cycle)
2. Polls the Deployment spec every 30 s
3. If memory limits differ from the original 64 Mi, reverts them
4. This causes the OOMKill to recur, triggering a new alert and RR

The EA (EffectivenessAssessment) detects the revert via spec hash comparison:
- `postRemediationSpecHash` ≠ `currentSpecHash` → `spec_drift` flagged
- After N cycles, the RO's `CheckIneffectiveRemediationChain` blocks further
  automated remediation.

> **v1.2.0 note**: Spec hash computation now includes mounted ConfigMap content
> (#396), making drift detection more robust when an external actor modifies
> ConfigMaps rather than the Deployment spec directly. Hash-capture failures
> are surfaced via `PreRemediationHashCaptured` / `PostRemediationHashCaptured`
> conditions and a `degraded` status flag on the EA.

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics |
| Workflow | `increase-memory-limits-v1` (shipped with demo content) |
| HAPI Prometheus | Auto-enabled by `run.sh`, reverted by `cleanup.sh` ([manual enablement](../../docs/prometheus-toolset.md)) |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`). It uses the `increase-memory-limits-v1` workflow from the
memory-escalation scenario:

| Resource | Name |
|----------|------|
| ServiceAccount | `increase-memory-limits-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `increase-memory-limits-v1-runner` |
| ClusterRoleBinding | `increase-memory-limits-v1-runner` |

**Permissions**: `apps` deployments (get, list, patch), core pods (get, list)

## Automated Run

```bash
./scenarios/resource-contention/run.sh
```

Options:
- `--interactive` — pause at approval gate for manual decision
- `--no-validate` — skip the automated validation pipeline

The validate.sh checks the first cycle only (Completed/Remediated). The full
multi-cycle escalation takes 15-20 minutes and can be observed manually.

## Manual Step-by-Step

```bash
# 1. Deploy
kubectl apply -k scenarios/resource-contention/manifests       # Kind
kubectl apply -k scenarios/resource-contention/overlays/ocp    # OCP

# 2. Start external actor (background)
bash scenarios/resource-contention/scripts/external-actor.sh &

# 3. Observe OOMKills
kubectl get pods -n demo-resource-contention -w

# 4. Query Alertmanager for active alerts
# Kind
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  amtool alert query alertname=ContainerOOMKilling --alertmanager.url=http://localhost:9093

# OCP
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=ContainerOOMKilling --alertmanager.url=http://localhost:9093

# 5. Watch first remediation cycle
kubectl get rr -n kubernaut-system -w -o wide
# Expect: Analyzing → Executing → Verifying → Completed (Remediated)
```

### 6. Inspect AI Analysis

```bash
# Get the latest AIA resource
AIA=$(kubectl get aia -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)

# Root cause analysis: summary, severity, and remediation target
kubectl get $AIA -n kubernaut-system -o jsonpath='
Root Cause:  {.status.rootCauseAnalysis.summary}
Severity:    {.status.rootCauseAnalysis.severity}
Target:      {.status.rootCauseAnalysis.remediationTarget.kind}/{.status.rootCauseAnalysis.remediationTarget.name}
'; echo

# Selected workflow and LLM rationale
kubectl get $AIA -n kubernaut-system -o jsonpath='
Workflow:    {.status.selectedWorkflow.workflowId}
Confidence:  {.status.selectedWorkflow.confidence}
Rationale:   {.status.selectedWorkflow.rationale}
'; echo

# Alternative workflows considered
kubectl get $AIA -n kubernaut-system -o jsonpath='{range .status.alternativeWorkflows[*]}  Alt: {.workflowId} (confidence: {.confidence}) -- {.rationale}{"\n"}{end}' # no output if empty
```

### 7. Watch external actor revert + subsequent cycles

```bash
# External actor log: "[external-actor] Reverting to original value..."
# Cycles 2-3: new RRs with IncreaseMemoryLimits
# Final: ManualReviewRequired
```

### 8. Kill external actor and set proper limits

```bash
kill %1
kubectl set resources deployment/contention-app -n demo-resource-contention \
  --limits=memory=256Mi --requests=memory=128Mi
```

## Cleanup

```bash
./scenarios/resource-contention/cleanup.sh
```

## Pipeline Timeline (OCP observed — first cycle)

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy (64 Mi limit) | T+0:00 | — |
| OOMKill begins | T+0:03 | immediate (64 MB > 64 Mi) |
| Alert fires | T+0:45 | 30 s `for:` + scrape interval |
| RR created | T+0:50 | 5 s |
| AA completes | T+2:06 | ~76 s investigation (5 poll cycles) |
| WFE completes (64→128 Mi) | T+2:20 | ~14 s job execution |
| EA completes (healthScore: 1) | T+3:06 | ~46 s health check |
| **Cycle 1 total** | **~3 min** | |

## BDD Specification

```gherkin
Feature: Resource Contention — external actor interference detection

  Background:
    Given a cluster with Kubernaut services and a real LLM backend
      And "contention-app" is deployed with 64Mi memory limit (causes OOMKill)
      And an external actor script monitors and reverts memory limit changes

  Scenario: First remediation cycle succeeds
    When the ContainerOOMKilling alert fires
    Then the LLM selects IncreaseMemoryLimits (64→128Mi, confidence 0.95)
      And the WFE doubles memory limits to 128Mi
      And EA confirms healthScore 1.0 (spec hashes match)
      And RR completes with outcome Remediated

  Scenario: External actor reverts cause escalation (multi-cycle)
    When the first remediation completes
      And the external actor reverts memory limits to 64Mi
      And the OOMKill recurs, creating a new RR
    Then the EA detects spec_drift (post-remediation hash ≠ current hash)
      And after repeated cycles, the RO blocks with ManualReviewRequired
      And a ManualReviewNotification is sent
```

## Acceptance Criteria

- [ ] Workload OOMKills with 64 Mi limit
- [ ] Alert fires within ~45 s
- [ ] First cycle: IncreaseMemoryLimits selected (confidence ≥ 0.9)
- [ ] First cycle: WFE completes, EA healthScore = 1.0
- [ ] First cycle: RR outcome = `Remediated`
- [ ] External actor detects and reverts the memory limit change
- [ ] OOMKill recurs after revert
- [ ] (Extended) After N cycles: RO detects ineffective chain → `ManualReviewRequired`
