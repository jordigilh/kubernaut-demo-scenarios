# Scenario #168: Memory Escalation — Diminishing Returns Detection

## Overview

Demonstrates Kubernaut's **diminishing returns detection**. An `ml-worker` container
allocates 8 Mi every 2 seconds to a memory-backed emptyDir, causing repeated OOMKills.
The first cycle successfully increases the memory limit, but the OOMKill recurs because
the root cause is unbounded allocation, not insufficient limits. On the second occurrence,
the platform recognises the pattern and escalates to human review instead of repeatedly
applying the same ineffective remedy.

**Key differentiator**: The platform knows when to *stop* automating and hand off to a human.

**Signal**: `ContainerOOMKilling` — container terminated with OOMKilled reason
**Root cause**: Unbounded memory allocation (simulated leak) in ml-worker
**Cycle 1 remediation**: `IncreaseMemoryLimits` (64 Mi → 128 Mi, 2x factor)
**Escalation**: `ManualReviewRequired` after 2–3 cycles (see [Escalation Paths](#escalation-paths))

## Escalation Paths

The number of cycles before escalation depends on how the platform detects
ineffectiveness. Two paths are possible:

### Path A — LLM-driven (2 cycles, observed on OCP)

The LLM reviews the Cycle 1 effectiveness assessment (healthScore=0) and the
remediation history from DataStorage. On Cycle 2, it concludes that repeating
IncreaseMemoryLimits is futile and **declines to select a workflow**:

> *"Previous IncreaseMemoryLimits remediation failed (0% effectiveness) because
> memory limits cannot fix memory leaks."*
>
> Contributing factors: `"Previous ineffective remediation attempt"`

The AA reports `no_matching_workflows` → RO escalates to `ManualReviewRequired`.

### Path B — RO guard-driven (3 cycles)

If the LLM re-selects IncreaseMemoryLimits on Cycle 2 (128 Mi → 256 Mi), the
OOMKill recurs a third time. The RO's `CheckConsecutiveFailures` guard detects
that the same signal fingerprint has produced multiple Failed or Completed-but-
ineffective RRs and blocks the third RR with `ManualReviewRequired`.

Both paths produce the same business outcome: the platform stops automating and
escalates to a human. Path A is a stronger demonstration because it shows the LLM
*reasoning about prior remediation effectiveness*.

## Signal Flow

```
Cycle 1 — Automated remediation
──────────────────────────────────
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} > 0
  → ContainerOOMKilling alert (severity: critical, for: 30s)
  → AlertManager webhook → Gateway → RemediationRequest
  → Signal Processing
  → AI Analysis (HAPI + Claude Sonnet 4 on Vertex AI)
    → Root cause: memory limit too low for workload (64 Mi, consumes 8 Mi/2s)
    → Contributing factors: memory-backed emptyDir, predictable growth
    → Selects IncreaseMemoryLimits (confidence 0.95, factor 2x)
    → Approval: required (production environment, critical severity)
  → WorkflowExecution: increase limits 64 Mi → 128 Mi
  → Effectiveness Monitor: healthScore=0 (OOMKill recurs — remedy was ineffective)

Cycle 2+ — Escalation (two possible paths)
──────────────────────────────────
Path A (2 cycles — LLM-driven):
  → New ContainerOOMKilling alert fires (128 Mi limit exceeded)
  → Gateway → new RemediationRequest
  → AI Analysis: LLM reviews Cycle 1 EA (healthScore=0) and prior history
    → "memory limits cannot fix memory leaks"
    → No workflows selected (WorkflowResolutionFailed)
  → RO: ManualReviewRequired → notification sent to human reviewer

Path B (3 cycles — RO guard-driven):
  → Cycle 2: OOMKill → IncreaseMemoryLimits (128 → 256 Mi) → EA healthScore=0
  → Cycle 3: OOMKill → RO CheckConsecutiveFailures blocks
  → ManualReviewRequired → notification sent to human reviewer
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services deployed |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics scraping |
| Workflow catalog | `increase-memory-limits-v1` registered in DataStorage |

## Automated Run

```bash
./scenarios/memory-escalation/run.sh
```

Options:
- `--interactive` — pause at approval step for manual approval
- `--no-validate` — skip the validation pipeline (deploy only)

## Manual Step-by-Step

### 1. Deploy the workload

```bash
kubectl apply -k scenarios/memory-escalation/manifests/
```

This creates:
- A single-replica `ml-worker` Deployment (busybox) that writes 8 Mi every 2 s to
  a memory-backed emptyDir at `/dev/shm`
- Memory limits: 32 Mi request / 64 Mi limit
- A `PrometheusRule` that fires `ContainerOOMKilling` when
  `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} > 0` for 30 s

### 2. Observe initial OOMKill

The container hits 64 Mi in approximately 16 seconds and is OOM-killed:

```bash
kubectl get pods -n demo-memory-escalation
# NAME                        READY   STATUS      RESTARTS     AGE
# ml-worker-6f4947654f-xxxxx  0/1     OOMKilled   1 (5s ago)   20s
```

### 3. Wait for Cycle 1 pipeline

The `ContainerOOMKilling` alert fires after 30 s. The full pipeline completes in ~4 min:

```bash
kubectl get rr,sp,aa,we,ea -n kubernaut-system
```

The LLM will:
1. Investigate the OOMKilled container and read events
2. Identify that the 64 Mi limit is too low for the 8 Mi/2 s allocation rate
3. Select `IncreaseMemoryLimits` with `MEMORY_INCREASE_FACTOR=2` (64 Mi → 128 Mi)
4. Request human approval (critical severity in production environment)

### 4. Approve remediation

```bash
# Find and approve the RAR
kubectl get rar -n kubernaut-system
kubectl patch rar <RAR_NAME> -n kubernaut-system --type=merge --subresource=status \
  -p '{"status":{"decision":"Approved","decidedBy":"human"}}'
```

### 5. Observe Cycle 1 result

After approval, the WFE increases the memory limit and restarts the pod:

```bash
kubectl get deployment ml-worker -n demo-memory-escalation \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
# 128Mi

kubectl get pods -n demo-memory-escalation
# Running briefly, then OOMKilled again (~32s with 128Mi)
```

The EA evaluates effectiveness and records `healthScore: 0` — the OOMKill recurred,
meaning the remediation was technically successful but *ineffective*.

### 6. Observe escalation (Cycle 2 or 3)

When the OOMKill recurs, a new RR is created. The outcome depends on which
escalation path the platform takes (see [Escalation Paths](#escalation-paths)):

**Path A (LLM-driven, 2 cycles):** The LLM reviews the Cycle 1 EA result
(`healthScore=0`) and remediation history. It reasons:

> *"Previous IncreaseMemoryLimits remediation failed (0% effectiveness) because
> memory limits cannot fix memory leaks."*

It intentionally declines to select a workflow (`no_matching_workflows`), and the
RR outcome is `ManualReviewRequired`:

```bash
kubectl get rr -n kubernaut-system -o wide
# rr-xxx-yyy  Completed  Remediated              demo-memory-escalation  (Cycle 1)
# rr-xxx-zzz  Failed     ManualReviewRequired    demo-memory-escalation  (Cycle 2)
```

**Path B (RO guard-driven, 3 cycles):** The LLM re-selects IncreaseMemoryLimits
on Cycle 2 (128 Mi → 256 Mi). After a third OOMKill, the RO's
`CheckConsecutiveFailures` guard blocks the third RR:

```bash
kubectl get rr -n kubernaut-system -o wide
# rr-xxx-aaa  Completed  Remediated              demo-memory-escalation  (Cycle 1)
# rr-xxx-bbb  Completed  Remediated              demo-memory-escalation  (Cycle 2)
# rr-xxx-ccc  Blocked    ManualReviewRequired    demo-memory-escalation  (Cycle 3)
```

In both cases, a `ManualReviewRequired` notification is sent, flagging the issue
for human investigation of the underlying memory leak.

## Platform Notes

### OCP

The `run.sh` script auto-detects the platform and applies the `overlays/ocp/` kustomization via `get_manifest_dir()`. The overlay:

- Adds `openshift.io/cluster-monitoring: "true"` to the demo namespace
- Adds restricted `securityContext` to the ml-worker container (non-root, drop all capabilities, RuntimeDefault seccomp)
- Removes the `release` label from `PrometheusRule`

No manual steps required.

## Cleanup

```bash
./scenarios/memory-escalation/cleanup.sh
```

## Pipeline Timeline (OCP observed, Path A)

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy | T+0:00 | — |
| First OOMKill | T+0:16 | 16 s (64 Mi ÷ 8 Mi/2 s) |
| ContainerOOMKilling alert fires | T+1:38 | 30 s `for:` + scrape latency |
| Cycle 1: RR created | T+1:41 | 3 s after alert |
| Cycle 1: AA completes | T+3:06 | 1 min 31 s investigation |
| Cycle 1: Approval requested | T+3:06 | Immediate after AA |
| Cycle 1: Approved (manual) | T+4:26 | — |
| Cycle 1: WFE completes (64→128 Mi) | T+4:46 | 20 s job execution |
| Cycle 1: EA completes (healthScore=0) | T+5:26 | 60 s check window |
| Cycle 2: OOMKill recurs at 128 Mi | T+5:58 | 32 s (128 Mi ÷ 8 Mi/2 s) |
| Cycle 2: RR created | T+6:00 | — |
| Cycle 2: AA fails (no workflows) | T+7:31 | 91 s investigation |
| Cycle 2: ManualReviewRequired | T+7:31 | Immediate escalation |
| **Total** | **~8 min** | 2 cycles |

## BDD Specification

```gherkin
Feature: Diminishing returns detection and escalation

  Scenario: Repeated OOMKill triggers escalation after ineffective remediation
    Given a deployment "ml-worker" in namespace "demo-memory-escalation"
      And the container allocates 8 Mi every 2 s to a memory-backed emptyDir
      And the container has a 64 Mi memory limit
      And the "increase-memory-limits-v1" workflow is registered

    When the container is OOMKilled (64 Mi exceeded in ~16 s)
      And the ContainerOOMKilling alert fires (for: 30s)

    Then Cycle 1 begins:
      And Gateway creates a RemediationRequest
      And HAPI diagnoses OOMKill from insufficient limits
      And the LLM selects IncreaseMemoryLimits (factor 2x, confidence 0.95)
      And Approval is required (production environment, critical severity)
      And after approval, WFE doubles the memory limit (64 Mi → 128 Mi)
      And EA evaluates healthScore=0 (OOMKill recurred — ineffective)

    When the container is OOMKilled again (128 Mi exceeded in ~32 s)
      And a new ContainerOOMKilling alert fires

    Then escalation occurs via one of two paths:
      # Path A (LLM-driven, 2 cycles):
      And HAPI reviews Cycle 1 EA (healthScore=0) and remediation history
      And the LLM reasons "memory limits cannot fix memory leaks"
      And no workflows are selected (WorkflowResolutionFailed)
      And the RR outcome is ManualReviewRequired
      # Path B (RO guard-driven, 3 cycles):
      And the LLM re-selects IncreaseMemoryLimits (128 → 256 Mi)
      And after a third OOMKill, CheckConsecutiveFailures blocks the RR
      And the RR outcome is ManualReviewRequired
      # Common:
      And a notification is sent for human investigation
      And the platform stops automating and hands off to a human
```

## Acceptance Criteria

- [ ] ml-worker gets OOMKilled at 64 Mi within ~16 s
- [ ] ContainerOOMKilling alert fires (for: 30s)
- [ ] Cycle 1: LLM selects IncreaseMemoryLimits with factor 2x
- [ ] Cycle 1: Confidence >= 0.95
- [ ] Cycle 1: Approval required (production + critical)
- [ ] Cycle 1: WFE increases limits from 64 Mi to 128 Mi
- [ ] Cycle 1: EA healthScore=0 (remediation was ineffective)
- [ ] OOMKill recurs at 128 Mi after Cycle 1 remediation
- [ ] Escalation occurs via Path A (LLM declines — `no_matching_workflows`) or Path B (RO guard — `CheckConsecutiveFailures`)
- [ ] Final RR outcome = ManualReviewRequired
- [ ] LLM rationale references prior ineffective remediation (Path A)
- [ ] Notification sent to human reviewer
- [ ] Multiple RRs created (2 or 3, depending on escalation path)
- [ ] Works on both Kind and OCP
