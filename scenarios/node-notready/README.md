# Scenario #127: Node NotReady -- Cordon + Drain

## Overview

A worker node becomes NotReady (simulated by pausing the Kind container with Podman).
Kubernaut detects the node failure, cordons it to prevent new scheduling, and drains
existing workloads to healthy nodes.

| | |
|---|---|
| **Signal** | `KubeNodeNotReady` -- node in NotReady state for >1 min |
| **Fault injection** | `podman pause <worker-node>` (stops kubelet heartbeat) |
| **Remediation** | `kubectl cordon` + `kubectl drain` |

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Kind cluster | Multi-node with `kubernaut.ai/managed=true` label |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics |
| Podman | Required to pause/unpause Kind node container |
| Workflow catalog | `cordon-drain-v1` registered in DataStorage |

> **Kind-only for v1.2**: This scenario uses `podman pause` to simulate kubelet
> failure, which only works on Kind clusters where nodes are containers. On OCP,
> `run.sh` exits early with a message. OCP support (via `virsh suspend` for
> libvirt-backed nodes) is planned for v1.3 (#286).

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `cordon-drain-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `cordon-drain-v1-runner` |
| ClusterRoleBinding | `cordon-drain-v1-runner` |

**Permissions**:

| API group | Resource | Verbs |
|-----------|----------|-------|
| core | nodes | get, list, patch, update |
| core | pods | get, list |
| core | pods/eviction | create |

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
./scenarios/node-notready/run.sh
```

### Manual Step-by-Step

#### 1. Deploy workload and simulate node failure

Run `./scenarios/node-notready/run.sh --no-validate` through node pause, or apply manifests
from `scenarios/node-notready/manifests/` and run `inject-node-failure.sh` as in `run.sh`.

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/node-notready/overlays/ocp/
```

</details>

#### 2. Wait for alert and watch pipeline

After the `KubeNodeNotReady` alert fires (~1–2 min), watch Kubernaut resources:

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  amtool alert query alertname=KubeNodeNotReady --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=KubeNodeNotReady --alertmanager.url=http://localhost:9093
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

#### 4. Approve the RAR (when using `--interactive`)

```bash
kubectl get rar -n kubernaut-system
kubectl patch rar <RAR_NAME> -n kubernaut-system --type=merge --subresource=status \
  -p '{"status":{"decision":"Approved","decidedBy":"operator"}}'
```

#### 5. Verify remediation

```bash
kubectl get nodes
kubectl get pods -n demo-node -o wide
```

#### 6. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
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
