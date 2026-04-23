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
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
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
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
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

#### Expected LLM Reasoning (v1.3 baseline)

When Kubernaut's AI analysis processes this scenario, the LLM typically reasons as follows:

| Field | Expected Value |
|-------|---------------|
| **Root Cause** | Node kubernaut-demo-worker became NotReady due to kubelet failure. After the 60-second node-monitor-grace-period, all node conditions transitioned to Unknown and NoSchedule/NoExecute taints were applied, evicting pods from the node. |
| **Severity** | critical |
| **Target Resource** | Node/kubernaut-demo-worker |
| **Workflow Selected** | cordon-drain-v1 (`CordonDrainNode`) |
| **Confidence** | 0.88 |
| **Approval** | required (sensitive resource kind: Node) |

**Key Reasoning Chain:**

1. Runs `kubectl_top_nodes` and `kubectl_describe(Node)` — identifies NotReady status, all conditions Unknown.
2. Reads node events — confirms kubelet stopped heartbeating, unreachable taints applied.
3. Enriches via `get_cluster_resource_context` — confirms cluster-scoped node with no GitOps/Helm management.
4. Queries pods in affected namespace — confirms service degraded (2/3 replicas).
5. Selects `cordon-drain-v1` — canonical remediation for persistent NotReady, matching `whenToUse` criteria.

> **Why this matters**: Shows the LLM handling node-level failures with appropriate caution — the approval policy automatically requires human review for Node resources, regardless of confidence.

#### LLM Investigation Trace (v1.3)

The tables below show the full tool-call sequence and token consumption observed
during a Kind run with `claude-sonnet-4-6` on platform version `1.3.0-rc11`.

**Phase 1 — Root Cause Analysis (8 LLM turns)**

| Turn | Tool calls | Prompt (chars) | What happened |
|------|-----------|----------------|---------------|
| 1 | `todo_write`, `kubectl_top_nodes`, `kubectl_describe(Node/kubernaut-demo-worker)`, `kubectl_events(Node/…)` | 4 586 | Planned investigation; identified NotReady, all conditions Unknown, cgroup warnings |
| 2 | `todo_write` | 4 932 | Updated plan: enrich cluster context |
| 3 | `get_cluster_resource_context(Node/kubernaut-demo-worker)`, `kubernetes_jq_query` | 12 437 | Cluster context: node taints, allocatable resources, JQ query for eviction details |
| 4 | `todo_write` | 12 688 | Assessed: kubelet failure, 60s grace period, pods evicted |
| 5 | `kubectl_get_by_kind_in_namespace(Pod, demo-node)`, `kubectl_get_by_kind_in_namespace(Pod, kubernaut-system)` | 17 308 | Checked affected workloads: web-service 2/3 replicas, platform pods evicted |
| 6 | `todo_write` | 17 476 | Root cause finalized |
| 7 | `todo_write` | 26 661 | Prepared RCA submission |
| 8 | *submit_result (RCA)* | 26 798 | Target: Node/kubernaut-demo-worker — kubelet failure, cgroup misconfiguration |

**Phase 2 — Workflow Selection (8 LLM turns)**

| Turn | Tool calls | Prompt (chars) | What happened |
|------|-----------|----------------|---------------|
| 1 | `todo_write` | 8 584 | Planned workflow search |
| 2 | `list_available_actions` | 8 972 | Fetched ActionTypes — identified `CordonDrainNode`, `CordonNode`, `DrainNode` |
| 3 | `todo_write` | 10 509 | Evaluated: CordonDrainNode combines both operations |
| 4 | `list_workflows(CordonDrainNode)` | 10 811 | Found `cordon-drain-v1` |
| 5 | `todo_write` | 12 256 | Confirmed match with `whenToUse` criteria |
| 6 | `get_workflow(cordon-drain-v1)` | 12 644 | Reviewed full workflow definition |
| 7 | `todo_write` | 15 884 | Prepared submission |
| 8 | *submit_result_with_workflow* | 16 110 | Selected cordon-drain-v1 (0.88 confidence) |

**Totals**

| Metric | Value |
|--------|-------|
| **Total tokens** | 123 671 (118 380 prompt + 5 291 completion) |
| **Total tool calls** | 18 |
| **LLM turns** | 16 (8 RCA + 8 Workflow) |
| **Peak prompt size** | 26 798 chars (RCA submit) |

> **Note**: The LLM used `kubectl_top_nodes` and `kubernetes_jq_query` for deeper
> cluster-level investigation (not just pod-level tools). It also checked pods in
> both `demo-node` and `kubernaut-system` namespaces to assess the blast radius
> of the node failure before submitting RCA.

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
