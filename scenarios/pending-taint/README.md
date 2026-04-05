# Scenario #122: Pending Pods -- Node Taint Removal

## Overview

A worker node has a `maintenance=scheduled:NoSchedule` taint that blocks pod scheduling.
Pods targeting that node via `nodeSelector` remain stuck in Pending. Kubernaut's LLM
investigates, identifies the taint as the root cause, and removes it.

**Signal**: `KubePodNotScheduled` -- pods Pending for >3 min
**Root cause**: Node taint blocking scheduling
**Remediation**: `kubectl taint nodes <node> maintenance-`

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Kind cluster | Multi-node with `kubernaut.ai/demo-taint-target=true` label on one worker |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
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

**Permissions**: core nodes (get, list, patch, update), core pods (get, list)

## Automated Run

```bash
./scenarios/pending-taint/run.sh
```

## Manual Step-by-Step

### 1. Apply taint and deploy workload

Follow `./scenarios/pending-taint/run.sh --no-validate` (taint + deploy), or run the full
script and use `--interactive` to pause at approval.

### 2. Wait for alert and watch pipeline

After the `KubePodNotScheduled` alert fires (~3 min), watch Kubernaut resources:

```bash
# Query Alertmanager for active alerts
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  amtool alert query alertname=KubePodNotScheduled --alertmanager.url=http://localhost:9093

kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system -w
```

### 3. Inspect AI Analysis

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

### 4. Approve the RAR (when using `--interactive`)

```bash
kubectl get rar -n kubernaut-system
kubectl patch rar <RAR_NAME> -n kubernaut-system --type=merge --subresource=status \
  -p '{"status":{"decision":"Approved","decidedBy":"operator"}}'
```

### 5. Verify remediation

```bash
kubectl get pods -n demo-taint
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.taints[*]}{.key}={.value}:{.effect}{" "}{end}{"\n"}{end}'
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
