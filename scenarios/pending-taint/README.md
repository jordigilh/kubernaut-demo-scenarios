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
| LLM backend | Real LLM (not mock) via HAPI |
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

#### Expected LLM Reasoning (v1.2 baseline)

When Kubernaut's AI analysis processes this scenario, the LLM typically reasons as follows:

| Field | Expected Value |
|-------|---------------|
| **Root Cause** | Pod cannot be scheduled because the only node matching its node selector has a maintenance taint (maintenance=scheduled:NoSchedule) that prevents scheduling. |
| **Severity** | high |
| **Target Resource** | Node/kubernaut-demo-worker (ns: ) |
| **Workflow Selected** | remove-taint-v1 |
| **Confidence** | 0.95 |
| **Approval** | required (sensitive resource kind: Node) |

**Key Reasoning Chain:**

1. Detects Pending pod with unmet scheduling constraints.
2. Identifies NoSchedule taint on the target node preventing scheduling.
3. Selects taint removal as the appropriate remediation.

> **Why this matters**: Demonstrates the LLM's ability to analyze scheduling constraints and identify node-level taints as the root cause of pod scheduling failures.

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
