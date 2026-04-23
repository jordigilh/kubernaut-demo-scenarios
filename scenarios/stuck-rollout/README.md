# Scenario #130: Stuck Rollout

## Overview

A deployment update gets stuck because the new image tag doesn't exist. After exceeding
`progressDeadlineSeconds` (120 s), Kubernetes marks the rollout as not progressing. Kubernaut
detects the `KubeDeploymentRolloutStuck` alert, diagnoses the bad image reference, and
rolls back to the previous working revision.

An interesting aspect of this scenario is the LLM's workflow selection: it considers
both `RollbackDeployment` (confidence 0.95) and an alternative `CrashLoopRollback`
workflow (confidence 0.75), correctly preferring the former because the pods are in
`ImagePullBackOff`, not `CrashLoopBackOff`.

| | |
|---|---|
| **Signal** | `KubeDeploymentRolloutStuck` — Progressing condition is False for >1 min |
| **Root cause** | Non-existent image tag `quay.io/kubernaut-cicd/demo-http-server:99.99.99-doesnotexist` |
| **Remediation** | `kubectl rollout undo` restores previous working revision |
| **Approval** | **Required** — production environment (`run.sh` enforces deterministic approval) |

## Signal Flow

```
kube_deployment_status_condition{condition="Progressing",status="false"} == 1
  → KubeDeploymentRolloutStuck alert (severity: critical, for: 1m)
  → AlertManager webhook → Gateway → RemediationRequest
  → Signal Processing
  → AI Analysis (KA + Claude Sonnet 4 on Vertex AI)
    → Root cause: invalid image tag causing ImagePullBackOff
    → Contributing factors: invalid tag, config error in spec, rolling update blocking
    → Selected: RollbackDeployment (confidence 0.95)
    → Alternative considered: CrashLoopRollback (0.75, rejected — wrong failure mode)
    → Approval: may be required (production environment, critical severity)
  → WorkflowExecution: kubectl rollout undo deployment/checkout-api
  → Effectiveness Monitor: healthScore=1 (all 3 replicas Running)
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services deployed |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | With kube-state-metrics scraping |
| Workflow catalog | `rollback-deployment-v1` registered in DataStorage |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `rollback-deployment-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `rollback-deployment-v1-runner` |
| ClusterRoleBinding | `rollback-deployment-v1-runner` |

**Permissions**:

| API group | Resource | Verbs |
|-----------|----------|-------|
| `apps` | deployments | get, list, patch, update |
| `apps` | replicasets | get, list |
| core | pods | get, list |

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
./scenarios/stuck-rollout/run.sh
```

Options:
- `--interactive` — pause at approval step for manual approval
- `--no-validate` — skip the validation pipeline (deploy + inject only)

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/stuck-rollout/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Deploy the workload

```bash
kubectl apply -k scenarios/stuck-rollout/manifests/

kubectl wait --for=condition=Available deployment/checkout-api \
  -n demo-rollout --timeout=120s
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/stuck-rollout/overlays/ocp/

kubectl wait --for=condition=Available deployment/checkout-api \
  -n demo-rollout --timeout=120s
```

</details>

This creates a 3-replica `checkout-api` Deployment running `quay.io/kubernaut-cicd/demo-http-server:1.0.0`,
a Service, and a PrometheusRule.

#### 2. Verify healthy state

```bash
kubectl get pods -n demo-rollout
# NAME                            READY   STATUS    RESTARTS   AGE
# checkout-api-84b5c88cd4-98m5t   1/1     Running   0          6s
# checkout-api-84b5c88cd4-c8crh   1/1     Running   0          6s
# checkout-api-84b5c88cd4-qxjvx   1/1     Running   0          6s
```

#### 3. Establish baseline (15 s)

Wait briefly for Prometheus to capture the healthy state before fault injection.

#### 4. Inject bad image

```bash
bash scenarios/stuck-rollout/inject-bad-image.sh
```

The script runs `kubectl set image deployment/checkout-api api=quay.io/kubernaut-cicd/demo-http-server:99.99.99-doesnotexist`.
New pods enter `ImagePullBackOff` immediately. The rollout strategy (`RollingUpdate`)
keeps the old pods running while the new ReplicaSet fails to become ready.

```bash
kubectl get pods -n demo-rollout
# checkout-api-84b5c88cd4-98m5t   1/1     Running             0          2m
# checkout-api-84b5c88cd4-c8crh   1/1     Running             0          2m
# checkout-api-84b5c88cd4-qxjvx   1/1     Running             0          2m
# checkout-api-xxxxxxxxxx-yyyyy   0/1     ImagePullBackOff    0          30s
```

#### 5. Wait for alert

The `KubeDeploymentRolloutStuck` alert requires two conditions:
1. `progressDeadlineSeconds` exceeded (120 s) — Kubernetes sets `Progressing=False`
2. Alert `for: 1m` — Prometheus waits 1 more minute to confirm

Total time from injection to alert: **~3 min** (Kind) / **~6 min** (OCP, longer scrape intervals).

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# open http://localhost:9090/alerts
```

<details>
<summary><strong>OCP</strong></summary>

On OCP, Prometheus is exposed via a Route. Open the **Observe → Alerting** page in
the OpenShift console, or port-forward to `thanos-querier`:

```bash
kubectl port-forward -n openshift-monitoring svc/thanos-querier 9090:9091
# open http://localhost:9090
```

</details>

#### 6. Monitor the pipeline

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert query alertname=KubeDeploymentRolloutStuck --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=KubeDeploymentRolloutStuck --alertmanager.url=http://localhost:9093
```

</details>

```bash
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

The LLM will:
1. Investigate the stuck rollout and inspect pod events
2. Identify `quay.io/kubernaut-cicd/demo-http-server:99.99.99-doesnotexist` as the invalid image tag
3. Note the deployment has a previous healthy revision available
4. Select `RollbackDeployment` (confidence 0.95) over `CrashLoopRollback` (0.75)
5. Request human approval (critical severity in production)

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

#### Expected LLM Reasoning (v1.3 baseline)

When Kubernaut's AI analysis processes this scenario, the LLM typically reasons as follows:

| Field | Expected Value |
|-------|---------------|
| **Root Cause** | Deployment rollout stuck due to a non-existent image tag (`99.99.99-doesnotexist`) causing ImagePullBackOff on all new pods, exceeding the progress deadline. |
| **Severity** | critical |
| **Target Resource** | Deployment/checkout-api (ns: demo-rollout) |
| **Workflow Selected** | rollback-deployment-v1 |
| **Confidence** | 0.98 |
| **Approval** | required (production environment) |
| **Alternatives** | crashloop-rollback-v1 (0.65) — wrong failure mode (CrashLoopBackOff vs ImagePullBackOff); crashloop-rollback-risk-v1 (0.55) — wrong risk tolerance and failure mode |

**Key Reasoning Chain:**

1. Describes the Deployment, identifies mismatched replica counts between old and new ReplicaSets.
2. Lists pods, sees new pods stuck in `ImagePullBackOff` while old pods remain healthy.
3. Checks events to confirm `Failed to pull image` errors with non-existent tag.
4. Recognizes this as a stuck rollout (not a crash) and selects `RollbackDeployment`.

> **Why this matters**: Demonstrates the LLM's ability to distinguish a stuck rollout from a simple crash and select rollback rather than restart.

#### LLM Investigation Trace (v1.3)

The table below shows the full tool-call sequence and token consumption observed
during a Kind run with `claude-sonnet-4-6` on platform version `1.3.0-rc7`.

**Phase 1 — Root Cause Analysis** (6 LLM turns, 55 839 tokens, ~61 s)

| Turn | Tool calls | Prompt (chars) | Tokens | What happened |
|------|-----------|----------------|--------|---------------|
| 1 | `todo_write` (plan) | 4 492 | 4 911 | Planned 6-step investigation |
| 2 | `kubectl_describe(Deployment/checkout-api)` | 4 835 | 5 133 | Identified stuck rollout, ProgressDeadlineExceeded |
| 3 | `kubectl_get_by_kind_in_namespace(Pod)`, `todo_write` | 13 464 | 8 594 | Listed pods: old RS healthy, new RS in ImagePullBackOff |
| 4 | `get_namespaced_resource_context(Deployment/checkout-api)`, `kubectl_events(Pod/...)`, `kubectl_events(Deployment/checkout-api)` | 25 407 | 8 960 | Gathered events confirming image pull failures |
| 5 | `todo_write` | 25 579 | 13 508 | Prepared RCA submission |
| 6 | *submit_result (RCA)* | 9 282 | 14 733 | Emitted root cause: bad image tag, severity critical |

**Phase 2 — Workflow Selection** (9 LLM turns, 68 908 tokens, ~48 s)

| Turn | Tool calls | Prompt (chars) | Tokens | What happened |
|------|-----------|----------------|--------|---------------|
| 7 | `todo_write` (plan) | 9 691 | 4 276 | Planned 4-step workflow selection |
| 8 | `list_available_actions` (page 1) | 15 776 | 4 402 | Fetched first page of ActionTypes |
| 9 | `list_available_actions` (page 2) | 20 637 | 6 027 | Identified `RollbackDeployment` |
| 10 | `todo_write` + `list_workflows(RollbackDeployment)` | 21 185 | 7 416 | Listed workflows for the matching ActionType |
| 11 | `todo_write` + `list_workflows` result | 24 312 | 7 573 | Reviewed workflow list |
| 12 | `todo_write` + `get_workflow(rollback-deployment-v1)` | 24 934 | 8 769 | Fetched full workflow definition |
| 13 | `todo_write` | 28 325 | 8 945 | Reviewed workflow preconditions |
| 14 | `todo_write` | 28 699 | 10 216 | Prepared final submission |
| 15 | *submit_result (workflow)* | — | 11 284 | Selected rollback-deployment-v1 (0.98 confidence) |

**Totals**

| Metric | Value |
|--------|-------|
| **Total tokens** | 124 747 |
| **Total tool calls** | 18 (4 K8s + 3 context/events + 2 catalog + 2 workflow + 7 planning) |
| **LLM turns** | 15 |
| **Wall-clock time** | ~109 s |
| **Peak prompt size** | 28 699 chars (end of workflow selection phase) |

> **Note**: The LLM did not need `kubectl_get_by_name` here because the root
> cause was visible directly from the Deployment describe and pod listing —
> no ConfigMap or Secret comparison was required.

#### 8. Approve (if required) and verify remediation

> [!NOTE]
> The LLM may or may not request human approval depending on its confidence and
> the assessed risk. Check the AIA output above: if `Approval: true`, a
> `RemediationApprovalRequest` (RAR) will be created and the pipeline pauses
> until you approve it. If `Approval: false`, the pipeline continues
> automatically and you can skip the approval step below.

```bash
# Check whether approval is pending
kubectl get rar -n kubernaut-system
```

If a RAR exists, approve it:

```bash
kubectl patch rar <RAR_NAME> -n kubernaut-system --type=merge --subresource=status \
  -p '{"status":{"decision":"Approved","decidedBy":"human"}}'
```

Verify remediation:

```bash
kubectl get pods -n demo-rollout
# All 3 replicas Running with quay.io/kubernaut-cicd/demo-http-server:1.0.0 (no ImagePullBackOff pods)

kubectl rollout history deployment/checkout-api -n demo-rollout
# REVISION  CHANGE-CAUSE
# 2         <none>        (bad image)
# 3         <none>        (rollback to revision 1)
```

#### 9. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Cleanup

```bash
./scenarios/stuck-rollout/cleanup.sh
```

## Pipeline Timeline (OCP observed)

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy + baseline | T+0:00 | — |
| Inject bad image | T+0:15 | — |
| progressDeadlineSeconds exceeded | T+2:15 | 120 s deadline |
| KubeDeploymentRolloutStuck fires | T+6:08 | `for: 1m` + OCP scrape latency |
| RR created | T+6:11 | 3 s after alert |
| AA completes | T+7:43 | 91 s investigation (6 poll cycles) |
| Approval requested | T+7:43 | Immediate |
| Approved (manual) | T+9:43 | — |
| WFE completes (rollback) | T+10:13 | 30 s job execution |
| EA completes (healthScore=1) | T+11:13 | 60 s health check |
| **Total** | **~11 min** | (6 min waiting for alert on OCP) |

## BDD Specification

```gherkin
Feature: Stuck rollout remediation via deployment rollback

  Scenario: Non-existent image tag causes stuck rollout
    Given a deployment "checkout-api" in namespace "demo-rollout"
      And the deployment has 3 healthy replicas running quay.io/kubernaut-cicd/demo-http-server:1.0.0
      And progressDeadlineSeconds is 120s
      And the "rollback-deployment-v1" workflow is registered

    When the image is updated to "quay.io/kubernaut-cicd/demo-http-server:99.99.99-doesnotexist"
      And new pods enter ImagePullBackOff
      And the rollout exceeds progressDeadlineSeconds (120s)
      And the KubeDeploymentRolloutStuck alert fires (for: 1m)

    Then Gateway receives the alert via AlertManager webhook
      And Signal Processing enriches with severity=critical
      And KA diagnoses stuck rollout from invalid image tag
      And contributing factors include: invalid tag, config error, rolling update blocking
      And the LLM selects RollbackDeployment (confidence 0.95)
      And an alternative CrashLoopRollback is considered but rejected (0.75)
      And Approval is required (production environment, critical severity)
      And after approval, WFE runs "kubectl rollout undo"
      And the original quay.io/kubernaut-cicd/demo-http-server:1.0.0 image is restored
      And all 3 replicas become Running/Ready
      And Effectiveness Monitor confirms healthScore=1
      And no ImagePullBackOff pods remain
```

## Acceptance Criteria

- [ ] Deployment starts healthy with 3 replicas (quay.io/kubernaut-cicd/demo-http-server:1.0.0)
- [ ] Bad image causes ImagePullBackOff on new ReplicaSet pods
- [ ] Old pods remain running (rolling update strategy preserves availability)
- [ ] Rollout exceeds progressDeadlineSeconds (120 s)
- [ ] KubeDeploymentRolloutStuck alert fires
- [ ] LLM selects RollbackDeployment (not CrashLoopRollback or other)
- [ ] Confidence >= 0.95
- [ ] Approval required (production + critical)
- [ ] Rollback restores original image (revision 3 = rollback to 1)
- [ ] All 3 replicas Running/Ready after rollback
- [ ] No ImagePullBackOff pods remain
- [ ] EA confirms healthScore=1
- [ ] Works on both Kind and OCP
