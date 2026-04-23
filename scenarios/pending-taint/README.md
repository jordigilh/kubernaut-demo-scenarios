# Scenario #122: Pending Pods -- Node Taint Removal

## Overview

A worker node has a `maintenance=scheduled:NoSchedule` taint that blocks pod scheduling.
Pods targeting that node via `nodeSelector` remain stuck in Pending. Kubernaut's LLM
investigates, identifies the taint as the root cause, and removes it.

| | |
|---|---|
| **Signal** | `KubePodNotScheduled` -- pods Pending for >3 min |
| **Root cause** | Node taint blocking scheduling |
| **Remediation** | `kubectl taint nodes <node> maintenance-` |

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Kind cluster | Multi-node (the inject script auto-labels a worker with `kubernaut.ai/demo-taint-target=true` if no node has it) |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | With kube-state-metrics |
| Workflow catalog | `remove-taint-v1` registered in DataStorage |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `remove-taint-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `remove-taint-v1-runner` |
| ClusterRoleBinding | `remove-taint-v1-runner` |

**Permissions**:

| API group | Resource | Verbs |
|-----------|----------|-------|
| core | nodes | get, list, patch, update |
| core | pods | get, list |

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
./scenarios/pending-taint/run.sh
```

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/pending-taint/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Apply taint and deploy workload

First, apply the maintenance taint to a worker node. The inject script auto-labels
a worker with `kubernaut.ai/demo-taint-target=true` if no node has the label yet:

```bash
bash scenarios/pending-taint/inject-taint.sh
```

Then deploy the workload (pods will remain Pending because of the taint):

```bash
kubectl apply -k scenarios/pending-taint/manifests/
kubectl get pods -n demo-taint
# batch-processor pods should show Pending
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/pending-taint/overlays/ocp/
kubectl get pods -n demo-taint
# batch-processor pods should show Pending
```

</details>

#### 2. Wait for alert and watch pipeline

After the `KubePodNotScheduled` alert fires (~3 min), watch Kubernaut resources:

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

```bash
# Query Alertmanager for active alerts

kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert query alertname=KubePodNotScheduled --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=KubePodNotScheduled --alertmanager.url=http://localhost:9093
```

</details>

```bash
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

#### 3. Inspect AI Analysis

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
| **Root Cause** | Pod is unschedulable because the only eligible node has an untolerated `NoSchedule` taint (`maintenance=scheduled`), and no other nodes match the pod's `nodeSelector`. Both replicas are stuck Pending with 0/3 nodes available. |
| **Severity** | medium |
| **Target Resource** | Deployment/batch-processor (ns: demo-taint) |
| **Workflow Selected** | remove-taint-v1 |
| **Confidence** | 0.95 |
| **Approval** | required (production environment) |

**Key Reasoning Chain:**

1. Fetches the Deployment by name (`kubectl_get_by_name`), describes the Pending pod, lists all nodes.
2. Describes the tainted node — confirms `maintenance=scheduled:NoSchedule` taint applied via `kubectl-taint`.
3. Identifies that the pod's `nodeSelector` restricts it to this specific node and has no matching toleration.
4. Selects `RemoveTaint` to unblock scheduling.

> **Why this matters**: Shows the LLM correlating pod scheduling failures with node taints and selecting the precise remediation (taint removal) rather than broader actions like cordon/drain.

#### LLM Investigation Trace (v1.3)

The table below shows the full tool-call sequence and token consumption observed
during a Kind run with `claude-sonnet-4-6` on platform version `1.3.0-rc7`.

**Phase 1 — Root Cause Analysis** (5 LLM turns, ~70 000 tokens, ~90 s)

| Turn | Tool calls | Tokens | What happened |
|------|-----------|--------|---------------|
| 1 | `todo_write` (plan) | — | Planned 4-step investigation |
| 2 | **`kubectl_get_by_name(Deployment/batch-processor)`**, `kubectl_describe(Pod/…)`, `kubectl_get_by_kind_in_cluster(Node)`, `kubectl_events(Pod/…)`, `kubectl_get_by_kind_in_namespace(Pod)` | — | 5 parallel calls: deployment, pod, all nodes, events, pod list |
| 3 | `kubectl_describe(Node/kubernaut-demo-worker)`, `todo_write` | — | Confirmed taint on target node |
| 4 | `get_namespaced_resource_context(…)`, `todo_write` | — | Gathered context |
| 5 | *submit_result (RCA)* | — | Root cause: untolerated NoSchedule taint |

**Phase 2 — Workflow Selection** (8 LLM turns, ~70 000 tokens, ~68 s)

| Turn | Tool calls | Tokens | What happened |
|------|-----------|--------|---------------|
| 6-7 | `list_available_actions` (pages 1-2) | — | Identified `RemoveTaint` ActionType |
| 8 | `list_workflows(RemoveTaint)` | — | Found `remove-taint-v1` |
| 9 | `get_workflow(remove-taint-v1)` | — | Reviewed workflow definition |
| 10 | *submit_result (workflow)* | — | Selected remove-taint-v1 (0.95 confidence) |

**Totals**

| Metric | Value |
|--------|-------|
| **Total tokens** | 140 600 |
| **Total tool calls** | 20 (5 K8s + 1 node-describe + 1 context + 2 catalog + 2 workflow + 9 planning) |
| **LLM turns** | 13 |
| **Wall-clock time** | ~158 s |

> **Note on `kubectl_get_by_name`**: The LLM fetched the Deployment directly
> by name in the first investigation turn alongside 4 other parallel calls,
> demonstrating efficient use of targeted lookups in multi-tool turns.

#### 4. Approve the RAR (when using `--interactive`)

```bash
kubectl get rar -n kubernaut-system
kubectl patch rar <RAR_NAME> -n kubernaut-system --type=merge --subresource=status \
  -p '{"status":{"decision":"Approved","decidedBy":"operator"}}'
```

#### 5. Verify remediation

```bash
kubectl get pods -n demo-taint
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.taints[*]}{.key}={.value}:{.effect}{" "}{end}{"\n"}{end}'
```

#### 6. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Cleanup

```bash
./scenarios/pending-taint/cleanup.sh
```

## BDD Specification

```gherkin
Given a Kind cluster with a worker node labeled kubernaut.ai/demo-taint-target=true
  And the worker node has a maintenance=scheduled:NoSchedule taint
  And the "remove-taint-v1" workflow is registered in DataStorage

When the batch-processor deployment is created with nodeSelector for the worker node
  And pods remain in Pending state because the taint blocks scheduling
  And the KubePodNotScheduled alert fires after 3 minutes

Then the LLM investigates the Pending pods and identifies the node taint
  And selects the RemoveTaint workflow
  And WE removes the maintenance taint from the worker node
  And the Pending pods get scheduled and reach Running state
  And EM confirms all pods are healthy
```

## Acceptance Criteria

- [ ] Worker node has NoSchedule taint applied
- [ ] Pods remain in Pending state
- [ ] Alert fires after 3 minutes
- [ ] LLM identifies the taint as root cause (not resource shortage)
- [ ] RemoveTaint workflow is selected
- [ ] Taint is removed from the node
- [ ] Pods transition from Pending to Running
- [ ] EM confirms healthy state
