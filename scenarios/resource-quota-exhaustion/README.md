# Scenario #171: Resource Quota Exhaustion — Policy Constraint Escalation

## Overview

Demonstrates Kubernaut distinguishing **policy constraints** from infrastructure
failures. When a Deployment's rolling update breaches the namespace ResourceQuota,
new pods are rejected at admission (`FailedCreate`). The LLM recognizes this as a
policy constraint that cannot be resolved by any available workflow and escalates to
`ManualReviewRequired`.

| | |
|---|---|
| **Signal** | `KubeResourceQuotaExhausted` — ReplicaSet desired > ready for >1 min |
| **Root cause** | Namespace memory quota (512 Mi) cannot accommodate both old pods (384 Mi used) and new pods (256 Mi each × 3 replicas = 768 Mi requested) |
| **Outcome** | `ManualReviewRequired` — no workflow matches; human must increase quota or scale down |
| **Approval** | **Required** — production environment (`run.sh` enforces deterministic approval) |

> **v1.2.0 note**: The LLM now receives ResourceQuota details (limits, usage) from
> the `LabelDetector`, making Path A (direct escalation) the dominant path. The LLM
> is quota-aware and will avoid selecting workflows like `IncreaseMemoryLimits` that
> would worsen quota pressure. The RR now transitions to `Completed` (not `Failed`)
> with outcome `ManualReviewRequired` when the LLM explicitly finds no applicable
> workflow.

## Signal Flow

```
Deployment scaled (3 replicas × 256Mi) → exceeds 512Mi quota
→ ReplicaSet FailedCreate (pods never reach Pending)
→ kube-state-metrics (spec_replicas > ready_replicas)
→ Prometheus (for: 1m) → AlertManager → Gateway webhook
→ RR → SP → AA (HAPI/LLM)
→ no_matching_workflows → ManualReviewRequired
→ ManualReviewNotification sent
```

The alert uses ReplicaSet-level metrics (`kube_replicaset_spec_replicas` vs
`kube_replicaset_status_ready_replicas`) because quota-rejected pods never exist —
they fail at admission, so pod-level metrics like `kube_pod_status_phase` won't catch
this.

## LLM Analysis (OCP observed)

Root cause analysis:

- **Summary**: Resource quota exhaustion preventing deployment rolling update.
  Namespace quota (512Mi memory) is insufficient to accommodate both old pods (384Mi)
  and new pods (256Mi) during rolling update transition.
- **Severity**: `medium`
- **Contributing factors**:
  - Insufficient namespace memory quota
  - Increased memory requirements in new pod specification
  - Rolling update strategy requiring temporary additional capacity
- **Affected resource**: `Deployment/api-server` in `demo-quota`

The LLM correctly identified this as a policy constraint (ResourceQuota) rather than
an infrastructure failure, found no matching workflow, and escalated with
`needsHumanReview: true`, `humanReviewReason: no_matching_workflows`.

## Two Valid Paths

| Path | Loops | Description |
|------|-------|-------------|
| **A (observed)** | 1 | LLM directly escalates to ManualReviewRequired |
| **B** | 2 | LLM tries a semantically similar workflow (e.g. IncreaseMemoryLimits), it fails, alert re-fires, second RR uses remediation history to self-correct (#323) |

Path A is the optimal outcome. Path B demonstrates the platform's self-correction
capability — the LLM learns from the failed first attempt.

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics |
| Workflows | No specific workflow needed (scenario proves escalation) |
| HAPI Prometheus | Auto-enabled by `run.sh`, reverted by `cleanup.sh` ([manual enablement](../../docs/prometheus-toolset.md)) |

### Workflow RBAC

This scenario intentionally has no matching remediation workflow. The LLM
recognizes the ResourceQuota constraint and escalates to `ManualReviewRequired`
rather than attempting automated remediation. No dedicated workflow
ServiceAccount is required.

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.

### Automated Run

```bash
./scenarios/resource-quota-exhaustion/run.sh
```

Options:
- `--interactive` — pause at approval gate for manual decision
- `--no-validate` — skip the automated validation pipeline

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/resource-quota-exhaustion/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Deploy

```bash
kubectl apply -k scenarios/resource-quota-exhaustion/manifests/
```

<details><summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/resource-quota-exhaustion/overlays/ocp/
```

</details>

#### 2. Wait for healthy state

```bash
kubectl wait --for=condition=Available deploy/api-server -n demo-quota --timeout=120s
```

#### 3. Exhaust quota

```bash
bash scenarios/resource-quota-exhaustion/exhaust-quota.sh
```

#### 4. Observe FailedCreate

```bash
kubectl describe rs -n demo-quota | grep -A3 FailedCreate
kubectl describe quota -n demo-quota
```

#### 5. Wait for alert

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert query alertname=KubeResourceQuotaExhausted --alertmanager.url=http://localhost:9093
```

<details><summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=KubeResourceQuotaExhausted --alertmanager.url=http://localhost:9093
```

</details>

#### 6. Monitor pipeline

```bash
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

Expect: Completed with outcome `ManualReviewRequired`.

#### 7. Inspect AI Analysis

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

#### Expected LLM Reasoning (v1.2 baseline)

When Kubernaut's AI analysis processes this scenario, the LLM typically reasons as follows:

| Field | Expected Value |
|-------|---------------|
| **Root Cause** | Deployment cannot scale because namespace ResourceQuota CPU/memory limits are exhausted. New pods fail at admission with FailedCreate events (never reach Pending). |
| **Severity** | high |
| **Target Resource** | ResourceQuota/demo-quota (ns: demo-quota) |
| **Workflow Selected** | ManualReviewRequired (no matching workflow) |
| **Confidence** | 0.85–0.95 |
| **Approval** | n/a — escalated to ManualReviewRequired before approval gate |

**Key Reasoning Chain:**

1. Detects ReplicaSet desired > ready with FailedCreate events due to quota rejection.
2. Identifies ResourceQuota as the constraint preventing pod creation.
3. No registered workflow can adjust namespace quotas, so the pipeline escalates to ManualReviewRequired.

> **Why this matters**: Demonstrates the LLM correctly identifying infrastructure quota constraints as the root cause, and the platform gracefully escalating when no automated remediation is available.

#### 8. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Cleanup

```bash
./scenarios/resource-quota-exhaustion/cleanup.sh
```

## Pipeline Timeline (OCP observed)

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy + baseline | T+0:00 | — |
| Exhaust quota (scale to 3 × 256Mi) | T+0:20 | after baseline |
| FailedCreate events | T+0:21 | immediate |
| Alert fires | T+3:15 | ~3 min `for:` + scrape interval |
| RR created | T+3:20 | 5 s |
| AA completes (no_matching_workflows) | T+4:51 | ~91 s investigation (6 poll cycles) |
| RR → Completed (ManualReviewRequired) | T+4:51 | — |
| ManualReviewNotification sent | T+4:51 | immediate |
| **Total** | **~5 min** | |

## BDD Specification

```gherkin
Feature: Resource Quota Exhaustion — policy constraint escalation

  Background:
    Given a cluster with Kubernaut services and a real LLM backend
      And namespace "demo-quota" has a ResourceQuota with 512Mi memory limit
      And deployment "api-server" is running (1 replica, 128Mi)

  Scenario: Path A — LLM directly escalates (1 loop)
    When the deployment is scaled to 3 replicas with 256Mi each (768Mi > 512Mi)
      And the new ReplicaSet receives FailedCreate events (quota exceeded)
      And the KubeResourceQuotaExhausted alert fires
    Then the alert flows through Gateway → SP → AA (HAPI)
      And the LLM identifies this as a policy constraint (ResourceQuota)
      And no matching workflow is found
      And AA sets needsHumanReview to true with reason "no_matching_workflows"
      And RR transitions to Completed with outcome ManualReviewRequired
      And a ManualReviewNotification is sent
      And the ResourceQuota remains exhausted (no automated fix)

  Scenario: Path B — LLM self-corrects after failed first attempt (2 loops)
    When the deployment is scaled to 3 replicas with 256Mi each (768Mi > 512Mi)
      And the KubeResourceQuotaExhausted alert fires
    Then the LLM selects a semantically similar workflow on the first RR
      And the workflow fails (cannot fix quota at namespace level)
      And the alert re-fires, creating a second RR
      And the LLM reviews remediation history and avoids repeating the mistake
      And the second RR escalates to ManualReviewRequired
```

## Acceptance Criteria

- [ ] ResourceQuota is correctly applied (512Mi limit)
- [ ] Deployment scale-up triggers FailedCreate events
- [ ] Alert fires within 2-3 minutes
- [ ] LLM correctly identifies policy constraint (not infra failure)
- [ ] RR outcome is `ManualReviewRequired`
- [ ] `needsHumanReview: true`, `humanReviewReason: no_matching_workflows`
- [ ] ManualReviewNotification is sent
- [ ] Quota remains exhausted (no automated changes)
- [ ] Remediation loops: 1 or 2 (both valid)
