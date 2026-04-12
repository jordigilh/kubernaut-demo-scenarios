# Scenario #168: Memory Escalation — Diminishing Returns Detection

## Overview

Demonstrates Kubernaut's **diminishing returns detection**. An `ml-worker` container
allocates 8 Mi every second to a memory-backed emptyDir, causing repeated OOMKills.
The first cycle successfully increases the memory limit, but the OOMKill recurs because
the root cause is unbounded allocation, not insufficient limits. On the second occurrence,
the platform recognises the pattern and escalates to human review instead of repeatedly
applying the same ineffective remedy.

**Key differentiator**: The platform knows when to *stop* automating and hand off to a human.

| | |
|---|---|
| **Signal** | `ContainerOOMKilling` — container terminated with OOMKilled reason |
| **Root cause** | Unbounded memory allocation (simulated leak) in ml-worker |
| **Cycle 1 remediation** | `IncreaseMemoryLimits` or `GracefulRestart` (model-dependent) |
| **Escalation** | `ManualReviewRequired` after 2–3 cycles (see [Escalation Paths](#escalation-paths)) |

## Escalation Paths

The number of cycles before escalation depends on how the platform detects
ineffectiveness. Three paths have been observed:

### Path A — LLM-driven (2 cycles, observed on OCP with Sonnet 4)

The LLM reviews the Cycle 1 effectiveness assessment (healthScore=0) and the
remediation history from DataStorage. On Cycle 2, it concludes that repeating
IncreaseMemoryLimits is futile and **declines to select a workflow**:

> *"Previous IncreaseMemoryLimits remediation failed (0% effectiveness) because
> memory limits cannot fix memory leaks."*
>
> Contributing factors: `"Previous ineffective remediation attempt"`

The AA reports `no_matching_workflows` → RO escalates to `ManualReviewRequired`.

### Path B — RO guard-driven (3+ cycles, not yet functional)

If the LLM re-selects a workflow on subsequent cycles, the RO should detect
the pattern via `CheckIneffectiveRemediationChain` and block. However, this
guardrail is **not implemented** in v1.2.0-rc2 (see [Known Issues](#known-issues)).
The existing `CheckConsecutiveFailures` guard only counts `Failed` RRs and resets
on `Completed` — since the workflow itself succeeds each time, the counter stays 0.

### Path C — Alternate workflow (observed on Kind with Sonnet 4.6)

The LLM respects the `whenNotToUse` guidance ("When the OOMKill is caused by a
memory leak") and selects `GracefulRestart` instead of `IncreaseMemoryLimits`.
Multiple cycles of GracefulRestart occur, each completing as `Remediated` but
the OOMKill recurs within seconds. Without a working RO guardrail (Path B),
cycles repeat until the test timeout.

### Model behavior notes

The escalation path depends heavily on the LLM model (see [kubernaut-docs#97](https://github.com/jordigilh/kubernaut-docs/issues/97)):
- **Sonnet 4** (OCP): willing to decline entirely → Path A (2 cycles, escalation)
- **Sonnet 4.6** (Kind): prefers to pick an alternative workflow → Path C (no escalation)

Both behaviors are valid. Path A is the strongest demonstration because it shows
the LLM *reasoning about prior remediation effectiveness*. Path C validates
multi-cycle recurrence detection (once the RO guardrail is implemented).

## Signal Flow

```
Cycle 1 — Automated remediation
──────────────────────────────────
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} > 0
  → ContainerOOMKilling alert (severity: critical, for: 30s)
  → AlertManager webhook → Gateway → RemediationRequest
  → Signal Processing
  → AI Analysis (HAPI + LLM on Vertex AI)
    → Root cause: memory limit too low for workload (64 Mi, consumes 8 Mi/s)
    → Contributing factors: memory-backed emptyDir, predictable growth
    → Selects IncreaseMemoryLimits or GracefulRestart (model-dependent)
    → Approval: required (production environment, critical severity)
  → WorkflowExecution: increase limits or rolling restart
  → Effectiveness Monitor: healthScore=0 (OOMKill recurs — remedy was ineffective)

Cycle 2+ — Escalation (three possible paths)
──────────────────────────────────
Path A (2 cycles — LLM-driven, Sonnet 4):
  → New ContainerOOMKilling alert fires (128 Mi limit exceeded)
  → Gateway → new RemediationRequest
  → AI Analysis: LLM reviews Cycle 1 EA (healthScore=0) and prior history
    → "memory limits cannot fix memory leaks"
    → No workflows selected (WorkflowResolutionFailed)
  → RO: ManualReviewRequired → notification sent to human reviewer

Path B (3+ cycles — RO guard-driven, blocked by kubernaut#616):
  → Cycle 2+: OOMKill → same workflow re-selected → EA healthScore=0
  → CheckIneffectiveRemediationChain should block (NOT YET IMPLEMENTED)
  → Currently: cycles repeat indefinitely

Path C (N cycles — alternate workflow, Sonnet 4.6):
  → LLM respects whenNotToUse → selects GracefulRestart instead
  → Cycle 2+: OOMKill recurs → GracefulRestart repeated
  → No escalation without working RO guardrail
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics scraping |
| Workflow catalog | `increase-memory-limits-v1` registered in DataStorage |
| HAPI Prometheus | Auto-enabled by `run.sh`, reverted by `cleanup.sh` ([manual enablement](../../docs/prometheus-toolset.md)) |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `increase-memory-limits-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `increase-memory-limits-v1-runner` |
| ClusterRoleBinding | `increase-memory-limits-v1-runner` |

**Permissions**:

| API group | Resources | Verbs |
|-----------|-----------|-------|
| `apps` | deployments | get, list, patch |
| core | pods | get, list |

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
./scenarios/memory-escalation/run.sh
```

Options:
- `--interactive` — pause at approval step for manual approval
- `--no-validate` — skip the validation pipeline (deploy only)

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/memory-escalation/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Deploy the workload

```bash
kubectl apply -k scenarios/memory-escalation/manifests/
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/memory-escalation/overlays/ocp
```

</details>

This creates:
- A single-replica `ml-worker` Deployment (busybox) that writes 8 Mi every second to
  a memory-backed emptyDir at `/dev/shm`
- Memory limits: 32 Mi request / 64 Mi limit
- A `PrometheusRule` that fires `ContainerOOMKilling` when
  `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} > 0` for 30 s

#### 2. Observe initial OOMKill

The container hits 64 Mi in approximately 8 seconds and is OOM-killed:

```bash
kubectl get pods -n demo-memory-escalation
# NAME                        READY   STATUS      RESTARTS     AGE
# ml-worker-6f4947654f-xxxxx  0/1     OOMKilled   1 (5s ago)   20s
```

#### 3. Wait for Cycle 1 pipeline

The `ContainerOOMKilling` alert fires after 30 s. The full pipeline completes in ~4 min:

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  amtool alert query alertname=ContainerOOMKilling --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=ContainerOOMKilling --alertmanager.url=http://localhost:9093
```

</details>

```bash
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

The LLM will:
1. Investigate the OOMKilled container and read events
2. Identify that the 64 Mi limit is too low for the 8 Mi/s allocation rate
3. Select `IncreaseMemoryLimits` (64 Mi → 128 Mi) or `GracefulRestart` depending
   on the model — Sonnet 4 prefers IncreaseMemoryLimits; Sonnet 4.6 may choose
   GracefulRestart due to the `whenNotToUse` memory leak exclusion
4. Request human approval (critical severity in production environment)

#### 4. Inspect AI Analysis

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

# Approval context and investigation narrative
kubectl get $AIA -n kubernaut-system -o jsonpath='
Approval:    {.status.approvalRequired}
Reason:      {.status.approvalContext.reason}
Confidence:  {.status.approvalContext.confidenceLevel}
'; echo
kubectl get $AIA -n kubernaut-system -o jsonpath='{.status.approvalContext.investigationSummary}'; echo
```

#### 5. Approve remediation

```bash
# Find and approve the RAR
kubectl get rar -n kubernaut-system
kubectl patch rar <RAR_NAME> -n kubernaut-system --type=merge --subresource=status \
  -p '{"status":{"decision":"Approved","decidedBy":"human"}}'
```

#### 6. Observe Cycle 1 result

After approval, the WFE increases the memory limit and restarts the pod:

```bash
kubectl get deployment ml-worker -n demo-memory-escalation \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
# 128Mi

kubectl get pods -n demo-memory-escalation
# Running briefly, then OOMKilled again (~16s with 128Mi)
```

The EA evaluates effectiveness and records `healthScore: 0` — the OOMKill recurred,
meaning the remediation was technically successful but *ineffective*.

#### 7. Observe escalation (Cycle 2+)

When the OOMKill recurs, a new RR is created. The outcome depends on which
escalation path the platform takes (see [Escalation Paths](#escalation-paths)):

**Path A (LLM-driven, 2 cycles — Sonnet 4):** The LLM reviews the Cycle 1 EA
result (`healthScore=0`) and remediation history. It reasons:

> *"Previous IncreaseMemoryLimits remediation failed (0% effectiveness) because
> memory limits cannot fix memory leaks."*

It intentionally declines to select a workflow (`no_matching_workflows`), and the
RR outcome is `ManualReviewRequired`:

```bash
kubectl get rr -n kubernaut-system -o wide
# rr-xxx-yyy  Completed  Remediated              demo-memory-escalation  (Cycle 1)
# rr-xxx-zzz  Failed     ManualReviewRequired    demo-memory-escalation  (Cycle 2)
```

**Path C (multi-cycle, no escalation — Sonnet 4.6):** The LLM respects the
`whenNotToUse` guidance and selects GracefulRestart (or re-selects
IncreaseMemoryLimits). Each cycle completes as `Remediated` but the OOMKill
recurs. Without the RO guardrail fix (kubernaut#616), cycles repeat:

```bash
kubectl get rr -n kubernaut-system -o wide
# rr-xxx-aaa  Completed  Remediated   demo-memory-escalation  (Cycle 1)
# rr-xxx-bbb  Completed  Remediated   demo-memory-escalation  (Cycle 2)
# rr-xxx-ccc  Completed  Remediated   demo-memory-escalation  (Cycle 3)
# ...
```

The automated `validate.sh` accepts multi-cycle recurrence (3+ RRs) as sufficient
proof that the platform detected the recurring issue, pending the kubernaut#616 fix.

#### 8. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Known Issues

| Issue | Impact | Status |
|-------|--------|--------|
| [kubernaut#616](https://github.com/jordigilh/kubernaut/issues/616) | RO `CheckIneffectiveRemediationChain` not implemented — Completed/Remediated cycles never trigger escalation | Open, targeting v1.2 RC3 |
| [kubernaut-docs#97](https://github.com/jordigilh/kubernaut-docs/issues/97) | LLM model choice affects escalation path (Sonnet 4 declines; Sonnet 4.6 picks alternatives) | Open, documentation |

## Cleanup

```bash
./scenarios/memory-escalation/cleanup.sh
```

## Pipeline Timeline (OCP observed, Path A)

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy | T+0:00 | — |
| First OOMKill | T+0:08 | 8 s (64 Mi ÷ 8 Mi/s) |
| ContainerOOMKilling alert fires | T+1:38 | 30 s `for:` + scrape latency |
| Cycle 1: RR created | T+1:41 | 3 s after alert |
| Cycle 1: AA completes | T+3:06 | 1 min 31 s investigation |
| Cycle 1: Approval requested | T+3:06 | Immediate after AA |
| Cycle 1: Approved (manual) | T+4:26 | — |
| Cycle 1: WFE completes (64→128 Mi) | T+4:46 | 20 s job execution |
| Cycle 1: EA completes (healthScore=0) | T+5:26 | 60 s check window |
| Cycle 2: OOMKill recurs at 128 Mi | T+5:42 | 16 s (128 Mi ÷ 8 Mi/s) |
| Cycle 2: RR created | T+6:00 | — |
| Cycle 2: AA fails (no workflows) | T+7:31 | 91 s investigation |
| Cycle 2: ManualReviewRequired | T+7:31 | Immediate escalation |
| **Total** | **~8 min** | 2 cycles |

## BDD Specification

```gherkin
Feature: Diminishing returns detection and escalation

  Scenario: Repeated OOMKill triggers escalation after ineffective remediation
    Given a deployment "ml-worker" in namespace "demo-memory-escalation"
      And the container allocates 8 Mi every second to a memory-backed emptyDir
      And the container has a 64 Mi memory limit
      And the "increase-memory-limits-v1" workflow is registered

    When the container is OOMKilled (64 Mi exceeded in ~8 s)
      And the ContainerOOMKilling alert fires (for: 30s)

    Then Cycle 1 begins:
      And Gateway creates a RemediationRequest
      And HAPI diagnoses OOMKill from insufficient limits
      And the LLM selects IncreaseMemoryLimits or GracefulRestart (model-dependent)
      And Approval is required (production environment, critical severity)
      And after approval, WFE executes the selected workflow
      And EA evaluates healthScore=0 (OOMKill recurred — remedy was ineffective)

    When the container is OOMKilled again
      And a new ContainerOOMKilling alert fires

    Then one of three escalation paths occurs:
      # Path A (LLM-driven, 2 cycles — Sonnet 4):
      And HAPI reviews prior history and infers ineffectiveness
      And the LLM declines to select a workflow (WorkflowResolutionFailed)
      And the RR outcome is ManualReviewRequired
      # Path B (RO guard-driven — blocked by kubernaut#616):
      And CheckIneffectiveRemediationChain should block after 3 ineffective cycles
      And (NOT YET IMPLEMENTED — cycles repeat indefinitely)
      # Path C (alternate workflow, multi-cycle — Sonnet 4.6):
      And the LLM selects GracefulRestart (respecting whenNotToUse)
      And multiple cycles complete as Remediated but OOMKill recurs
      And multi-cycle recurrence validates the platform detected the pattern
```

## Acceptance Criteria

- [ ] ml-worker gets OOMKilled at 64 Mi within ~8 s
- [ ] ContainerOOMKilling alert fires (for: 30s)
- [ ] Cycle 1: LLM selects IncreaseMemoryLimits or GracefulRestart (model-dependent)
- [ ] Cycle 1: Confidence >= 0.85
- [ ] Cycle 1: Approval required (production + critical)
- [ ] Cycle 1: WFE executes the selected workflow
- [ ] Cycle 1: EA healthScore=0 (remediation was ineffective)
- [ ] OOMKill recurs after Cycle 1 remediation
- [ ] Escalation occurs via Path A (LLM declines), Path B (RO guard — blocked by kubernaut#616), or Path C (multi-cycle recurrence)
- [ ] Path A: Final RR outcome = ManualReviewRequired, LLM rationale references prior ineffective remediation
- [ ] Path C: Multiple RRs created (3+), all Completed/Remediated — validates recurrence detection
- [ ] Multiple RRs created (2+, depending on escalation path)
- [ ] Works on both Kind and OCP
