# Scenario #120: CrashLoopBackOff Remediation

## Demo

![Kubernaut detecting and remediating a CrashLoopBackOff](crashloop-lite.gif)

## Overview

Demonstrates Kubernaut detecting a CrashLoopBackOff caused by a bad release
(command override on the Deployment spec) and performing an automatic rollback
to the previous working revision.

| | |
|---|---|
| **Signal** | `KubePodCrashLooping` -- restart count increasing rapidly |
| **Root cause** | Deployment spec patched with a crashing command (simulates bad binary release) |
| **Remediation** | `kubectl rollout undo` restores the previous healthy revision |
| **Approval** | **Required** — production environment (`run.sh` enforces deterministic approval) |

## Signal Flow

```
kube_pod_container_status_restarts_total increasing → KubePodCrashLooping alert
  → Gateway → SP → AA (KA + real LLM)
  → LLM diagnoses bad config causing CrashLoopBackOff
  → Selects GracefulRestart (rollback) workflow
  → RO → WE (kubectl rollout undo)
  → EM verifies pods running, restarts stabilized
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | With kube-state-metrics |
| Workflow catalog | `crashloop-rollback-v1` registered in DataStorage |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `crashloop-rollback-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `crashloop-rollback-v1-runner` |
| ClusterRoleBinding | `crashloop-rollback-v1-runner` |

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
./scenarios/crashloop/run.sh
```

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/crashloop/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Deploy the healthy workload

```bash
kubectl apply -k scenarios/crashloop/manifests/
kubectl wait --for=condition=Available deployment/worker -n demo-crashloop --timeout=120s
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/crashloop/overlays/ocp/
kubectl wait --for=condition=Available deployment/worker -n demo-crashloop --timeout=120s
```

</details>

#### 2. Verify healthy state

```bash
kubectl get pods -n demo-crashloop
# All pods should be Running with 0 restarts
```

<details>
<summary>Expected output</summary>

```
NAME                      READY   STATUS    RESTARTS   AGE
worker-6b8c9f4d5-x2k7p   1/1     Running   0          45s
```

</details>

#### 3. Inject bad release

```bash
bash scenarios/crashloop/inject-bad-release.sh
```

The script patches the Deployment to override the container command with one that
exits immediately (simulating a broken binary release). Pods will crash on startup.

#### 4. Observe CrashLoopBackOff

```bash
kubectl get pods -n demo-crashloop -w
# Pods cycle: Error -> CrashLoopBackOff -> Error -> ...
```

<details>
<summary>Expected output</summary>

```
NAME                      READY   STATUS             RESTARTS      AGE
worker-7f4a8b3c1-q9m2p   0/1     CrashLoopBackOff   3 (30s ago)   2m
```

</details>

#### 5. Wait for alert and pipeline

The alert fires after >3 restarts in 10 min (~2-3 min).

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

Query Alertmanager for active alerts:

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert query alertname=KubePodCrashLooping --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=KubePodCrashLooping --alertmanager.url=http://localhost:9093
```

</details>

Watch Kubernaut pipeline progression:

```bash
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

#### 6. Inspect AI Analysis

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
kubectl get $AIA -n kubernaut-system -o jsonpath='{range .status.alternativeWorkflows[*]}  Alt: {.workflowId} (confidence: {.confidence}) -- {.rationale}{"\n"}{end}'

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
| **Root Cause** | CrashLoopBackOff caused by a command override on the Deployment spec that makes the container exit immediately with code 1 (`echo fatal: bad release 1.1.0 -- aborting && exit 1`). The Deployment (generation 2) includes the crashing command; all new pods exit on startup until the spec is rolled back to revision 1 (no command override). |
| **Severity** | critical |
| **Target Resource** | Deployment/worker (ns: demo-crashloop) |
| **Workflow Selected** | crashloop-rollback-v1 |
| **Confidence** | 0.97 |
| **Approval** | required (production environment) |
| **Alternatives** | rollback-deployment-v1 (0.82) — scoped to progressDeadline expiry; crashloop-rollback-risk-v1 (0.71) — designed for low risk tolerance |

**Key Reasoning Chain:**

1. Detects CrashLoopBackOff with exit code 1 indicating a bad release.
2. Inspects Deployment spec and finds a command override added in the latest revision.
3. Previous revision (generation 1) had no command override and was healthy.
4. Identifies rollback as appropriate since the Deployment spec itself changed.

> **Why this matters**: Demonstrates the LLM's ability to trace a pod crash to a Deployment spec change (command override) and unambiguously select `crashloop-rollback-v1` over ConfigMap-focused workflows.

#### LLM Investigation Trace (v1.3)

The table below shows the full tool-call sequence and token consumption observed
during a Kind run with `claude-sonnet-4-6` on platform version `1.3.0-rc7`.

**Phase 1 — Root Cause Analysis** (4 LLM turns, 46 348 tokens, ~49 s)

| Turn | Tool calls | Prompt (chars) | Tokens | What happened |
|------|-----------|----------------|--------|---------------|
| 1 | `kubectl_describe(Pod/worker-…)`, `kubectl_events(Pod/worker-…)` | 4 614 | 4 995 | Identified CrashLoopBackOff, exit code 1 |
| 2 | `kubectl_get_by_kind_in_namespace(Pod)`, `kubectl_describe(Deployment/worker)`, **`kubectl_get_by_name(ConfigMap/worker-config-bad)`**, **`kubectl_get_by_name(ConfigMap/worker-config)`**, `kubectl_previous_logs(worker-…)` | 20 597 | 11 335 | Compared both ConfigMaps by name; confirmed invalid directive |
| 3 | `get_namespaced_resource_context(Deployment/worker)` | 28 722 | 14 492 | Gathered namespace labels and ownership context |
| 4 | *submit_result (RCA)* | 29 078 | 15 526 | Emitted root cause: bad ConfigMap, severity critical, target Deployment/worker |

**Phase 2 — Workflow Selection** (9 LLM turns, 64 598 tokens, ~57 s)

| Turn | Tool calls | Prompt (chars) | Tokens | What happened |
|------|-----------|----------------|--------|---------------|
| 5 | `todo_write` (plan) | 7 568 | 3 686 | Planned 4-step workflow selection |
| 6 | `list_available_actions` (page 1) | 7 875 | 3 787 | Fetched first page of ActionTypes |
| 7 | `list_available_actions` (page 2) | 13 960 | 5 405 | Fetched remaining ActionTypes; identified `RollbackDeployment` |
| 8 | `todo_write` + `list_workflows(RollbackDeployment)` | 18 789 | 6 917 | Listed workflows for the matching ActionType |
| 9 | `todo_write` | 19 733 | 7 055 | Updated progress |
| 10 | `todo_write` + `get_workflow(crashloop-rollback-v1)` | 22 860 | 8 377 | Fetched full workflow definition |
| 11 | `todo_write` | 23 810 | 8 533 | Updated progress |
| 12 | `todo_write` | 27 208 | 9 838 | Preparing final submission |
| 13 | *submit_result (workflow)* | 27 575 | 11 000 | Selected crashloop-rollback-v1 (0.97 confidence) |

**Totals**

| Metric | Value |
|--------|-------|
| **Total tokens** | 110 946 |
| **Total tool calls** | 18 (8 K8s + 2 catalog + 4 workflow + 4 planning) |
| **LLM turns** | 13 |
| **Wall-clock time** | ~106 s |
| **Peak prompt size** | 29 078 chars (end of RCA phase) |

> **Note on `kubectl_get_by_name`**: The LLM used the targeted lookup tool to
> fetch each ConfigMap individually by name rather than listing all ConfigMaps
> in the namespace. This keeps the prompt lean — only the two relevant
> ConfigMaps were returned (~2 KB each) instead of a full namespace listing.

#### 7. Verify remediation

```bash
kubectl get pods -n demo-crashloop
# All pods Running/Ready with no recent restarts
kubectl rollout history deployment/worker -n demo-crashloop
```

<details>
<summary>Expected output</summary>

```
NAME                      READY   STATUS    RESTARTS   AGE
worker-6b8c9f4d5-x2k7p   1/1     Running   0          60s
```

</details>

<details>
<summary>Troubleshooting</summary>

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Alert doesn't fire after 5 min | Prometheus not scraping kube-state-metrics | `kubectl get servicemonitor -A` and check targets in Prometheus UI |
| Pipeline stalls at SP | Gateway didn't forward the alert | Check Gateway logs: `kubectl logs -n kubernaut-system deploy/kubernaut-gateway` |
| WFE stays `Pending` | ServiceAccount missing or RBAC misconfigured | Verify SA exists: `kubectl get sa crashloop-rollback-v1-runner -n kubernaut-workflows` |
| Rollback didn't happen | WFE job failed | Check job logs: `kubectl logs -n kubernaut-workflows -l kubernaut.ai/workflow-execution --tail=50` |

</details>

#### 8. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Cleanup

```bash
./scenarios/crashloop/cleanup.sh
```

## BDD Specification

```gherkin
Given a Kind cluster with Kubernaut services and a real LLM backend
  And Prometheus is scraping kube-state-metrics
  And the "crashloop-rollback-v1" workflow is registered in the DataStorage catalog
  And the "worker" deployment is running healthily in namespace "demo-crashloop"

When the deployment is patched with a crashing command override (bad release)
  And pods enter CrashLoopBackOff with rapidly increasing restart counts
  And the KubePodCrashLooping alert fires (>3 restarts in 10 min)

Then Kubernaut Gateway receives the alert via Alertmanager webhook
  And Signal Processing enriches the signal with business labels
  And AI Analysis (KA + LLM) diagnoses CrashLoopBackOff from bad release
  And the LLM selects the "RollbackDeployment" workflow (crashloop-rollback-v1)
  And Remediation Orchestrator creates a WorkflowExecution
  And Workflow Execution rolls back the deployment to the previous revision
  And the pods start successfully with the restored healthy spec
  And Effectiveness Monitor confirms the deployment is healthy and restarts stabilized
```

## Acceptance Criteria

- [ ] Worker deployment starts healthy and serves traffic
- [ ] Command-override injection causes immediate CrashLoopBackOff
- [ ] Alert fires within 2-3 minutes of first crash
- [ ] LLM correctly diagnoses bad release (command override) as root cause
- [ ] Rollback restores the original healthy Deployment spec
- [ ] All pods become Running/Ready after rollback
- [ ] Restart count stabilizes (no further restarts)
- [ ] EM confirms successful remediation
