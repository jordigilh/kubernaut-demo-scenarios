# Scenario #124: PDB Deadlock

## Overview

Demonstrates Kubernaut leveraging **detected labels** (`pdbProtected`) to resolve a
PodDisruptionBudget deadlock during a node drain. The PDB has `minAvailable` equal to
the replica count, leaving zero allowed disruptions and blocking all voluntary evictions.
When an SRE initiates `kubectl drain` for maintenance, the drain hangs indefinitely.
Kubernaut detects the deadlock, relaxes the PDB, and the drain completes.

| | |
|---|---|
| **Detected label** | `pdbProtected: "true"` — LLM context includes PDB configuration |
| **Signal** | `KubePodDisruptionBudgetAtLimit` — PDB at 0 allowed disruptions for >3 min |
| **Remediation** | Patch PDB `minAvailable` from 2 to 1, unblocking the drain |
| **Approval** | **Required** — production environment (`run.sh` enforces deterministic approval) |

## Why This Scenario Matters

This reproduces a well-known Kubernetes anti-pattern where an overly conservative PDB
silently blocks node maintenance operations:

1. **SRE team sets the PDB**: After a production incident where a node drain took down
   all pods simultaneously, the SRE team adds `minAvailable: 2` to guarantee the
   payment service is always available during voluntary disruptions. This is a sensible
   availability protection.

2. **Maintenance window arrives**: Weeks later, a kernel CVE requires patching all worker
   nodes. The SRE runs `kubectl drain <worker-node>` to move workloads off the node
   before rebooting. The drain command uses the Kubernetes eviction API, which respects
   PDB constraints.

3. **The deadlock**: The eviction API asks the PDB "can I evict a pod?" The PDB says no
   -- `minAvailable: 2` with exactly 2 running pods means zero disruptions are allowed.
   The drain hangs silently. The SRE sees the node stuck in `SchedulingDisabled` state
   with no progress. Meanwhile, the security patching window is ticking.

This is insidious because the PDB setting was correct when applied (2 replicas, want
both available), but it creates a hard constraint that blocks ALL voluntary disruptions
-- including routine maintenance. The failure mode is a silent hang rather than a
visible error, and it only surfaces during maintenance operations that may happen weeks
or months after the PDB was created.

### Future Expansion: Rolling Update Variant

An alternative single-node variant exists where `maxSurge: 0` combined with the same
PDB creates a rolling update deadlock. Kubernetes must evict an old pod before creating
a new one (`maxSurge: 0`), but the PDB blocks eviction. This variant is planned for
single-node validation as a future expansion.

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind (multi-node) or OCP with Kubernaut services deployed |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | With kube-state-metrics |
| Workflow catalog | `relax-pdb-v1` registered in DataStorage |

### OCP-specific prerequisites

The deployment uses `nodeSelector: kubernaut.ai/managed=true`. The `run.sh`
script applies this label automatically to all worker nodes if fewer than two
are labelled. The `cleanup.sh` script removes the label afterwards.

For manual runs, label at least two workers before deploying:

```bash
kubectl label node <worker-1> kubernaut.ai/managed=true
kubectl label node <worker-2> kubernaut.ai/managed=true
```

At least two labeled workers are needed: one to drain, and one (or more) for
pods to reschedule onto.

### Kind-specific prerequisites

This scenario drains a worker node and expects pods (including WFE jobs) to
reschedule to the control-plane. `setup-demo-cluster.sh` handles both of
these automatically, but if you created the cluster manually:

1. **Control-plane `kubernaut.ai/managed=true` label** — the deployment
   uses `nodeSelector: kubernaut.ai/managed=true`. Without this label on the
   control-plane, evicted pods stay Pending after the worker is drained.

   ```bash
   kubectl label node <control-plane-node> kubernaut.ai/managed=true
   ```

2. **Control-plane NoSchedule taint removed** — the default taint
   `node-role.kubernetes.io/control-plane:NoSchedule` prevents both
   workload pods and WFE jobs from scheduling on the control-plane.

   ```bash
   kubectl taint nodes <control-plane-node> node-role.kubernetes.io/control-plane:NoSchedule-
   ```

> **Note:** kubernaut#498 tracks adding control-plane tolerations to WFE
> jobs so that taint removal is no longer required.

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `relax-pdb-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `relax-pdb-v1-runner` |
| ClusterRoleBinding | `relax-pdb-v1-runner` |

**Permissions**:

| API group | Resources | Verbs |
|-----------|-----------|-------|
| `policy` | poddisruptionbudgets | get, list, patch |

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
./scenarios/pdb-deadlock/run.sh
```

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/pdb-deadlock/run.sh
```

</details>

### Manual Step-by-Step

#### 0. (OCP only) Label worker nodes

```bash
kubectl label node <worker-1> kubernaut.ai/managed=true
kubectl label node <worker-2> kubernaut.ai/managed=true
```

#### 1. Deploy the workload with restrictive PDB

```bash
kubectl apply -k scenarios/pdb-deadlock/manifests/
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/pdb-deadlock/overlays/ocp
```

</details>

```bash
kubectl wait --for=condition=Available deployment/payment-service -n demo-pdb --timeout=120s
```

#### 2. Verify PDB state and pod placement

```bash
kubectl get pdb -n demo-pdb
# ALLOWED DISRUPTIONS = 0 (minAvailable=2 with 2 replicas)
kubectl get pods -n demo-pdb -o wide
# Both pods should be on the worker node
```

#### 3. Drain the worker node (will be blocked by PDB)

```bash
bash scenarios/pdb-deadlock/inject-drain.sh
```

#### 4. Observe the deadlock

```bash
kubectl get nodes
# Worker node shows SchedulingDisabled, but drain is stuck
kubectl get pods -n demo-pdb
# All pods still Running on the worker (PDB blocks eviction)
```

#### 5. Wait for alert and pipeline

The `KubePodDisruptionBudgetAtLimit` alert fires after 3 minutes at 0 allowed disruptions.

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert query alertname=KubePodDisruptionBudgetAtLimit --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=KubePodDisruptionBudgetAtLimit --alertmanager.url=http://localhost:9093
```

</details>

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
| **Root Cause** | PDB `payment-service-pdb` has `minAvailable=2` equal to the total replica count of 2, leaving zero disruptions allowed (`disruptionsAllowed=0`) and blocking all voluntary disruptions including node drains and rolling updates. |
| **Severity** | medium |
| **Target Resource** | PodDisruptionBudget/payment-service-pdb (ns: demo-pdb) |
| **Workflow Selected** | relax-pdb-v1 |
| **Confidence** | 0.95 |
| **Approval** | required (production environment) |
| **Alternatives** | None — `relax-pdb-v1` is a direct and precise match |

**Key Reasoning Chain:**

1. Fetches PDB by name (`kubectl_get_by_name`) and describes it — sees `minAvailable=2`, `disruptionsAllowed=0`.
2. Lists pods and nodes — confirms both pods are healthy, one node is cordoned for maintenance.
3. Finds the owning Deployment via `kubectl_find_resource` — confirms 2 replicas matching the PDB budget.
4. Recognizes this as a PDB deadlock (not a resource or config issue) and selects `RelaxPDB`.

> **Why this matters**: Shows the LLM reasoning beyond surface-level pod failures to identify infrastructure constraints (PDB) as the root cause. Also demonstrates use of `kubectl_get_by_name` for targeted PDB lookup.

#### LLM Investigation Trace (v1.3)

The table below shows the full tool-call sequence and token consumption observed
during a Kind run with `claude-sonnet-4-6` on platform version `1.3.0-rc7`.

**Phase 1 — Root Cause Analysis** (6 LLM turns, 46 967 tokens, ~80 s)

| Turn | Tool calls | Prompt (chars) | Tokens | What happened |
|------|-----------|----------------|--------|---------------|
| 1 | `todo_write` (plan) | 5 261 | 5 174 | Planned 6-step investigation |
| 2 | **`kubectl_get_by_name(PDB/payment-service-pdb)`**, `kubectl_describe(PDB/…)` | 5 661 | 5 438 | Fetched PDB directly by name: `minAvailable=2`, `disruptionsAllowed=0` |
| 3 | `todo_write` | 8 781 | 6 866 | Updated progress |
| 4 | `kubectl_get_by_kind_in_namespace(Pod)`, `kubectl_get_by_kind_in_cluster(Node)` | 8 866 | 7 052 | Confirmed pods healthy, one node cordoned |
| 5 | `kubectl_find_resource(Deployment/payment-service)`, `get_namespaced_resource_context(PDB/…)` | 14 909 | 9 502 | Found owning Deployment, gathered context |
| 6 | *submit_result (RCA)* | 21 606 | 12 935 | Root cause: PDB deadlock, severity medium |

**Phase 2 — Workflow Selection** (9 LLM turns, 60 353 tokens, ~39 s)

| Turn | Tool calls | Prompt (chars) | Tokens | What happened |
|------|-----------|----------------|--------|---------------|
| 7 | *submit_result (RCA response)* | 7 602 | 3 697 | RCA phase boundary |
| 8 | `todo_write` | 7 920 | 3 798 | Planned workflow selection |
| 9 | `list_available_actions` (page 1) | 14 005 | 5 418 | Fetched ActionTypes |
| 10 | `list_available_actions` (page 2) | 18 831 | 6 775 | Identified `RelaxPDB` |
| 11 | `todo_write` + `list_workflows(RelaxPDB)` | 19 153 | 6 903 | Found `relax-pdb-v1` |
| 12 | `todo_write` + `get_workflow(relax-pdb-v1)` | 20 111 | 7 431 | Reviewed workflow definition |
| 13 | `todo_write` | 20 457 | 7 610 | Confirmed preconditions met |
| 14 | `todo_write` | 23 930 | 8 941 | Prepared submission |
| 15 | *submit_result (workflow)* | 24 157 | 9 780 | Selected relax-pdb-v1 (0.95 confidence) |

**Totals**

| Metric | Value |
|--------|-------|
| **Total tokens** | 107 320 |
| **Total tool calls** | 18 (3 K8s-by-name + 2 K8s-list + 1 find + 1 context + 2 catalog + 2 workflow + 7 planning) |
| **LLM turns** | 15 |
| **Wall-clock time** | ~119 s |
| **Peak prompt size** | 24 157 chars (end of workflow selection) |

> **Note on `kubectl_get_by_name`**: The LLM used the targeted lookup to fetch
> the PDB directly by name on its very first investigation step, avoiding a
> namespace-wide PDB listing.

#### 7. Verify remediation

```bash
kubectl get pdb -n demo-pdb
# minAvailable should now be 1, ALLOWED DISRUPTIONS > 0
kubectl get nodes
# Worker node drain should complete (SchedulingDisabled)
kubectl get pods -n demo-pdb -o wide
# Pods should be Running on the control-plane node
```

#### 8. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Cleanup

```bash
bash scenarios/pdb-deadlock/cleanup.sh
```

## BDD Specification

```gherkin
Given a Kind cluster with a worker node and Kubernaut services with a real LLM backend
  And the "relax-pdb-v1" workflow is registered with detectedLabels: pdbProtected: "true"
  And the "payment-service" deployment has 2 replicas on the worker node
  And a PDB with minAvailable=2 is applied (blocking all disruptions)

When an SRE drains the worker node for maintenance
  And the drain hangs because the PDB blocks all pod evictions
  And the KubePodDisruptionBudgetAtLimit alert fires (0 allowed disruptions for 3 min)

Then Kubernaut detects the pdbProtected label
  And the LLM receives PDB context in its analysis prompt
  And the LLM selects the RelaxPDB workflow
  And WE patches the PDB minAvailable from 2 to 1
  And the blocked drain resumes and completes
  And pods reschedule to the control-plane node
  And EM verifies all pods are healthy after the drain
```

## Acceptance Criteria

- [ ] Pods are scheduled on the worker node (nodeSelector)
- [ ] PDB blocks node drain (ALLOWED DISRUPTIONS = 0)
- [ ] Worker node stuck in SchedulingDisabled state
- [ ] Alert fires after 3 minutes of deadlock
- [ ] LLM leverages `pdbProtected` detected label in diagnosis
- [ ] RelaxPDB workflow is selected
- [ ] PDB is patched to minAvailable=1
- [ ] Node drain completes after PDB relaxation
- [ ] Pods reschedule to control-plane node
- [ ] EM confirms all pods healthy
