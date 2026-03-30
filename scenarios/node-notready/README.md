# Scenario #127: Node NotReady -- Cordon + Drain

## Overview

A worker node becomes NotReady (simulated by pausing the Kind container with Podman).
Kubernaut detects the node failure, cordons it to prevent new scheduling, and drains
existing workloads to healthy nodes.

**Signal**: `KubeNodeNotReady` -- node in NotReady state for >1 min
**Fault injection**: `podman pause <worker-node>` (stops kubelet heartbeat)
**Remediation**: `kubectl cordon` + `kubectl drain`

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Kind cluster | Multi-node with `kubernaut.ai/managed=true` label |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics |
| Podman | Required to pause/unpause Kind node container |
| Workflow catalog | `cordon-drain-v1` registered in DataStorage |

## Automated Run

```bash
./scenarios/node-notready/run.sh
```

## Manual Step-by-Step

### 1. Deploy workload and simulate node failure

Run `./scenarios/node-notready/run.sh --no-validate` through node pause, or apply manifests
from `scenarios/node-notready/manifests/` and run `inject-node-failure.sh` as in `run.sh`.

### 2. Wait for alert and watch pipeline

After the `KubeNodeNotReady` alert fires (~1–2 min), watch Kubernaut resources:

```bash
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
'

# Selected workflow and LLM rationale
kubectl get $AIA -n kubernaut-system -o jsonpath='
Workflow:    {.status.selectedWorkflow.workflowId}
Confidence:  {.status.selectedWorkflow.confidence}
Rationale:   {.status.selectedWorkflow.rationale}
'

# Alternative workflows considered
kubectl get $AIA -n kubernaut-system -o jsonpath='{range .status.alternativeWorkflows[*]}  Alt: {.workflowId} (confidence: {.confidence}) -- {.rationale}{"\n"}{end}'

# Approval context and investigation narrative
kubectl get $AIA -n kubernaut-system -o jsonpath='
Approval:    {.status.approvalRequired}
Reason:      {.status.approvalContext.reason}
Confidence:  {.status.approvalContext.confidenceLevel}
'
kubectl get $AIA -n kubernaut-system -o jsonpath='{.status.approvalContext.investigationSummary}'
```

### 4. Approve the RAR (when using `--interactive`)

```bash
kubectl get rar -n kubernaut-system
kubectl patch rar <RAR_NAME> -n kubernaut-system --type=merge --subresource=status \
  -p '{"status":{"decision":"Approved","decidedBy":"operator"}}'
```

### 5. Verify remediation

```bash
kubectl get nodes
kubectl get pods -n demo-node -o wide
```

## Cleanup

```bash
./scenarios/node-notready/cleanup.sh
```

## Acceptance Criteria

- [ ] Worker node transitions to NotReady after `podman pause`
- [ ] Alert fires within 1-2 minutes
- [ ] LLM identifies node failure (not a network or pod issue)
- [ ] CordonDrainNode workflow is selected
- [ ] Node is cordoned (unschedulable)
- [ ] Node is drained (non-system pods evicted)
- [ ] Pods rescheduled to healthy nodes
- [ ] EM confirms all pods healthy on new nodes
