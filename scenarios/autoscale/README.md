# Scenario #126: Cluster Autoscaling -- Add Node via kubeadm join

## Overview

This scenario demonstrates Kubernaut diagnosing pod scheduling failures caused by resource exhaustion across all cluster nodes, and remediating by provisioning a new Kind worker node via `kubeadm join`.

The architecture uses **split responsibility** (Option B), mirroring how cloud autoscalers work in production:

```
Production:
  WE Job → calls AWS/GCP/Azure API → cloud provisions VM → VM runs kubeadm join

Kind Demo (equivalent):
  WE Job → writes ScaleRequest ConfigMap → host-side provisioner detects it
                                            → podman run (create container)
                                            → podman exec (kubeadm join)
                                            → kubectl label (workload node)
  WE Job → waits for new Node Ready → verifies pods rescheduled
```

The WE Job runs **unprivileged inside Kubernetes**. It writes a scale request and waits. The host-side provisioner agent is the Kind-specific equivalent of Karpenter (EKS), NAP (GKE), or `cluster-autoscaler`.

## Platform Compatibility

| Platform | Supported | Notes |
|----------|-----------|-------|
| **macOS / Kind** | Yes | Kind runs inside a Podman/Docker Desktop VM with capped memory (typically 4-8 GB), so the dynamic replica computation produces a manageable number of pods. |
| **Linux bare-metal / Kind** | **No** | Kind nodes inherit the full host memory. On high-memory hosts (e.g. 250 GB), the script computes hundreds of replicas to exhaust capacity. The resulting AlertManager webhook payload (~372 KB) exceeds the gateway's 100 KB defensive limit, so the alert is never ingested and the pipeline never triggers. |
| **OCP / Cloud** | Not tested | Would require a real cluster autoscaler (Karpenter, NAP, cluster-autoscaler) instead of the host-side provisioner agent. |

## Prerequisites

- Kind cluster created with `overlays/kind/kind-cluster-config.yaml` (multi-node: control-plane + 1 worker)
- Podman available on the host (used by the provisioner agent)
- Kubernaut services deployed with KA configured for a real LLM backend
- Kubernaut Agent Prometheus toolset (auto-enabled by `run.sh`, reverted by `cleanup.sh` — [manual enablement](../../docs/prometheus-toolset.md))
- `ProvisionNode` action type registered in DataStorage (migration 026)
- `provision-node-v1` workflow registered in the workflow catalog

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `provision-node-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `provision-node-v1-runner` |
| ClusterRoleBinding | `provision-node-v1-runner` |

**Permissions**:

| API group | Resources | Verbs |
|-----------|-----------|-------|
| core | configmaps | get, list, create, update |
| core | pods | get, list |

## BDD Specification

```gherkin
Feature: Cluster Autoscaling via Node Provisioning

  Scenario: Pods stuck Pending due to resource exhaustion trigger node provisioning
    Given a Kind cluster with 1 control-plane and 1 worker node
      And a demo-http-server Deployment "web-cluster" with 2 replicas running on the worker node
      And each replica requests 2Gi memory
      And the Kubernaut pipeline is active with a real LLM
      And the "provision-node-v1" workflow is registered in the catalog
      And the host-side provisioner agent is running

    When run.sh queries total allocatable memory across managed worker nodes
      And computes a replica count that exceeds total capacity (max_pods + 2)
      And scales the Deployment to that replica count
      And new pods enter Pending state with "Insufficient memory" events

    Then Prometheus fires KubePodSchedulingFailed alert after 2 minutes
      And Signal Processing enriches with node resource allocation data
      And the LLM identifies cluster-wide resource exhaustion as root cause
      And the LLM selects the ProvisionNode action type
      And Remediation Orchestrator creates a WorkflowExecution
      And the WE Job creates a ScaleRequest ConfigMap in kubernaut-system
      And the provisioner agent detects the request
      And the provisioner creates a new Kind node via podman + kubeadm join
      And the provisioner labels the new node kubernaut.ai/managed=true
      And the WE Job verifies the new node is Ready
      And previously-Pending pods schedule on the new node
      And EffectivenessAssessment confirms all pods are Running
```

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~15 min (Kind)

### Automated Run

```bash
./scenarios/autoscale/run.sh
```

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/autoscale/run.sh
```

</details>

This script:
1. Deploys the namespace, workload, and Prometheus rules
2. Starts the provisioner agent in the background
3. Queries allocatable memory and computes a replica count that exceeds node capacity
4. Scales the deployment to trigger Pending pods

### Manual Step-by-Step

> [!NOTE]
> The commands below default to Kind. For OCP, replace `kubectl apply -f scenarios/autoscale/manifests/`
> with `kubectl apply -k scenarios/autoscale/overlays/ocp/`, and use the OCP amtool command variant
> shown in the dropdown below.

```bash
# 1. Verify cluster has control-plane + 1 worker
kubectl get nodes

# 2. Deploy namespace and workload (2 replicas)
kubectl apply -f scenarios/autoscale/manifests/
kubectl wait --for=condition=Available deployment/web-cluster \
  -n demo-autoscale --timeout=60s

# 3. Deploy Prometheus alerting rules
kubectl apply -f scenarios/autoscale/manifests/prometheus-rule.yaml

# 4. Start the provisioner agent in background
./scenarios/autoscale/provisioner.sh &
PROVISIONER_PID=$!

# 5. Verify initial state (2 Running pods)
kubectl get pods -n demo-autoscale -o wide

# 6. Inject: scale beyond node capacity (compute dynamically or use a high count)
kubectl scale deployment/web-cluster --replicas=14 -n demo-autoscale

# 7. Verify some pods are Pending
kubectl get pods -n demo-autoscale   # some Running, rest Pending

# 8. Query Alertmanager for active alerts
# Kind
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert query alertname=KubePodSchedulingFailed --alertmanager.url=http://localhost:9093

# OCP
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=KubePodSchedulingFailed --alertmanager.url=http://localhost:9093

# 9. Watch Kubernaut pipeline
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

<details>
<summary><strong>OCP (amtool)</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=KubePodSchedulingFailed --alertmanager.url=http://localhost:9093
```

</details>

#### 10. Inspect AI Analysis

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

| Field | Expected Value |
|-------|---------------|
| **Root Cause** | Deployment web-cluster was manually scaled to 14 replicas with 2 GiB memory each (28 GiB total demand), exceeding the 3-node cluster's ~21.6 GiB total capacity. All nodes report 'Insufficient memory', leaving 6 pods permanently Pending/Unschedulable. |
| **Severity** | critical |
| **Target Resource** | Deployment/web-cluster (ns: demo-autoscale) |
| **Workflow Selected** | provision-node-v1 |
| **Confidence** | 0.92 |
| **Approval** | not required |
| **Alternatives** | N/A |

**Key Reasoning Chain:**

1. Describes the deployment and detects Pending pods with `FailedScheduling` events.
2. Lists all pods and nodes, runs `kubectl_top_nodes` and `kubectl_memory_requests_all_namespaces`.
3. Identifies cluster-level memory exhaustion — total demand exceeds total allocatable.
4. Selects `provision-node-v1` workflow to add capacity by provisioning a new worker node.

> **Why this matters**: Demonstrates the LLM's ability to diagnose cluster-level capacity exhaustion (not just namespace-level) and select an infrastructure-provisioning workflow rather than application-level fixes.

#### LLM Investigation Trace (v1.3)

| Metric | Value |
|--------|-------|
| **Total tokens** | 161,914 (156,723 prompt + 5,191 completion) |
| **Total tool calls** | 22 (15 investigation + 7 todo_write) |
| **LLM turns** | 17 |
| **Wall-clock time** | ~3 min 46 s (AA phase) |
| **Peak prompt size** | ~26k chars |

**Investigation tools used**: `kubectl_describe` (×3), `kubectl_events`, `kubectl_get_by_kind_in_namespace` (×2), `kubectl_get_by_kind_in_cluster`, `kubectl_top_nodes`, `kubectl_memory_requests_all_namespaces`, `get_namespaced_resource_context`, `list_available_actions` (×2), `list_workflows` (×2), `get_workflow`

> **Note**: The node was successfully provisioned and joined the cluster (kubelet bootstrap ~2 min).
> However, the WFE timed out before the provisioner could acknowledge completion.
> The remediation itself worked — 11/14 pods became Running on the new 4-node cluster.
> This is a WFE timeout configuration issue, not an LLM or workflow logic issue.

#### 11. Verify remediation

```bash
kubectl get nodes                          # 3rd node visible
kubectl get pods -n demo-autoscale -o wide # distributed across nodes
```

#### 12. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

#### 13. Cleanup

```bash
kill $PROVISIONER_PID
./scenarios/autoscale/cleanup.sh
```

## Acceptance Criteria

- [ ] demo-http-server Deployment manifests in `scenarios/autoscale/manifests/`
- [ ] WE Job workflow (remediate.sh) creates ScaleRequest and verifies fulfillment
- [ ] Host-side provisioner agent (provisioner.sh) watches and provisions nodes
- [ ] `deploy/remediation-workflows/autoscale/autoscale.yaml` with actionType `ProvisionNode` registered in DataStorage
- [ ] Prometheus alerting rule for `FailedScheduling` / `Insufficient` resources
- [ ] Full pipeline with real LLM: Gateway -> RO -> SP -> AA -> WE -> EM
- [ ] LLM identifies resource exhaustion and selects node provisioning workflow
- [ ] New node joins via kubeadm, `kubectl get nodes` shows it as Ready
- [ ] Previously Pending pods schedule on the new node
- [ ] `run.sh` automates the entire flow (including starting provisioner agent)
- [ ] README documents both automated and manual step-by-step execution
- [ ] Cleanup instructions for removing the extra node and provisioner

## Dynamic Scaling

`run.sh` computes the replica count at runtime:

1. Queries `allocatable.memory` from all nodes with `kubernaut.ai/managed=true`
2. Divides total allocatable by the per-pod request (2Gi) to get `max_pods`
3. Scales to `max_pods + 2` (minimum 8) to guarantee at least 2 pods stay Pending

This works regardless of host memory -- whether it's a Linux host exposing all RAM or a macOS Podman VM with a capped allocation.

## Cleanup

```bash
./scenarios/autoscale/cleanup.sh
```

This removes the namespace, scale-request ConfigMap, kills the provisioner, and deletes dynamically provisioned node containers from Podman.

## Notes

- **Production analogy**: The provisioner agent is the Kind equivalent of Karpenter (EKS), NAP (GKE), or cluster-autoscaler. In production, the WE Job would call a cloud API directly instead of writing a ConfigMap.
- **Security**: The WE Job runs unprivileged inside K8s. Only the host-side agent (outside K8s) has Podman access.
- **EM target**: The `RemediationTarget` should be the Deployment (pods now Running), not the cluster itself.
