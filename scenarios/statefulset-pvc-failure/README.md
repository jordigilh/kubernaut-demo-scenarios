# Scenario #137: StatefulSet PVC Failure — Stateful Workload Remediation

## Overview

Demonstrates Kubernaut detecting a StatefulSet-based workload with PVC disruption
causing a pod stuck in Pending, and performing automatic remediation by recreating the
missing PVC with the correct StorageClass and deleting the stuck pod to allow
rescheduling.

The LLM correctly detects `stateful: true` from the ownership chain, diagnoses the
PVC failure (non-existent StorageClass), and selects the `FixStatefulSetPVC` workflow.

| | |
|---|---|
| **Signal** | `KubeStatefulSetReplicasMismatch` — ready replicas < desired for >3 min |
| **Root cause** | PVC `data-kv-store-2` references non-existent StorageClass `broken-storage-class` |
| **Remediation** | `fix-statefulset-pvc-v1` — recreates PVC with correct SC, deletes stuck pod |

## Signal Flow

```
kube_statefulset_status_replicas_ready < kube_statefulset_status_replicas for 3m
→ KubeStatefulSetReplicasMismatch alert
→ Gateway → SP → AA (KA + LLM)
→ LLM detects stateful=true, diagnoses PVC failure (broken StorageClass)
→ Selects FixStatefulSetPVC (confidence 0.95)
→ Rego: is_sensitive_resource (StatefulSet) → AwaitingApproval
→ Operator approves → WFE (recreate PVC, delete stuck pod)
→ EA verifies all 3 replicas ready
```

## LLM Analysis (OCP observed)

Root cause analysis:

- **Summary**: StatefulSet kv-store has 2/3 replicas running due to pod kv-store-2
  stuck in Pending status. Root cause is PVC data-kv-store-2 cannot be provisioned
  because it references non-existent StorageClass 'broken-storage-class'.
- **Severity**: `high`
- **Contributing factors**:
  - Misconfigured StorageClass reference in StatefulSet volumeClaimTemplate
  - Missing StorageClass 'broken-storage-class'
  - PVC provisioning failure blocking pod scheduling
- **Workflow**: `FixStatefulSetPVC` (confidence 0.95)
- **Detected labels**: `stateful: true`

## Approval Gate

StatefulSets are classified as sensitive resources by the Rego policy
(`is_sensitive_resource`), so approval is **always required** regardless of
environment. The approval reason is:

> *"Sensitive resource kind (Node/StatefulSet) - requires manual approval"*

This is by design — StatefulSet operations are inherently riskier (ordering
guarantees, persistent data) and warrant human oversight.

> **Note**: The `--auto-approve` flag currently does not handle the StatefulSet
> approval gate automatically. See [#57](https://github.com/jordigilh/kubernaut-demo-scenarios/issues/57).

## Fault Injection

The `inject-pvc-issue.sh` script:

1. Scales the StatefulSet to 2 replicas (removes `kv-store-2`, releases its PVC)
2. Deletes `data-kv-store-2` PVC (now unprotected)
3. Creates a replacement PVC with StorageClass `broken-storage-class` (doesn't exist)
4. Scales back to 3 replicas — `kv-store-2` recreated but stuck in Pending

The workflow detects the non-Bound PVC, deletes it, recreates it with the cluster
default StorageClass, and the pod recovers.

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | With kube-state-metrics |
| StorageClass | Cluster default (Kind: `standard`, OCP: `ocs-storagecluster-ceph-rbd`) |
| Workflow | `fix-statefulset-pvc-v1` (shipped with demo content) |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `fix-statefulset-pvc-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `fix-statefulset-pvc-v1-runner` |
| ClusterRoleBinding | `fix-statefulset-pvc-v1-runner` |

**Permissions**:

| API group | Resources | Verbs |
|-----------|-----------|-------|
| apps | statefulsets | get, list |
| core | persistentvolumeclaims | get, list, create, delete |
| core | pods | get, list, delete |

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
./scenarios/statefulset-pvc-failure/run.sh
```

Options:
- `--interactive` — pause at approval gate for manual approve/reject
- `--no-validate` — skip the automated validation pipeline

> Because StatefulSets always require approval, `--interactive` is recommended.

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/statefulset-pvc-failure/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Deploy

```bash
kubectl apply -k scenarios/statefulset-pvc-failure/manifests
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/statefulset-pvc-failure/overlays/ocp/
```

</details>

#### 2. Wait for StatefulSet (3 replicas)

```bash
kubectl rollout status sts/kv-store -n demo-statefulset --timeout=180s
```

#### 3. Inject PVC failure

```bash
bash scenarios/statefulset-pvc-failure/inject-pvc-issue.sh
```

`kv-store-2` should move to `Pending` (broken StorageClass).

#### 4. Query Alertmanager for active alerts (~3 min)

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert query alertname=KubeStatefulSetReplicasMismatch --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP (amtool)</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=KubeStatefulSetReplicasMismatch --alertmanager.url=http://localhost:9093
```

</details>

#### 5. Monitor pipeline

```bash
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

Expect: Analyzing → AwaitingApproval.

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
| **Root Cause** | StatefulSet replica mismatch caused by kv-store-2 stuck in Pending due to PVC `data-kv-store-2` referencing a non-existent StorageClass `broken-storage-class`. The PVC was manually created with an incorrect storageClassName, causing repeated ProvisioningFailed errors and preventing pod scheduling. |
| **Severity** | critical |
| **Target Resource** | StatefulSet/kv-store (ns: demo-statefulset) |
| **Workflow Selected** | fix-statefulset-pvc-v1 (`FixStatefulSetPVC`) |
| **Confidence** | 0.95 |
| **Approval** | required (sensitive resource kind: StatefulSet) |

**Key Reasoning Chain:**

1. Fetches StatefulSet and lists all pods — identifies kv-store-2 Pending while kv-store-0/1 are Running.
2. Describes pod and PVC — confirms `data-kv-store-2` stuck with `ProvisioningFailed: storageclass.storage.k8s.io "broken-storage-class" not found`.
3. Lists PVCs and StorageClasses cluster-wide — confirms `broken-storage-class` does not exist, healthy PVCs use `standard`.
4. Enriches via `get_namespaced_resource_context` — confirms StatefulSet ownership, `environment=staging`.
5. Selects `fix-statefulset-pvc-v1` — deletes broken PVC and recreates with correct StorageClass.

> **Why this matters**: Demonstrates the LLM handling stateful workloads with appropriate caution, including mandatory manual approval for sensitive resource types. The LLM correctly identified a storage-class mismatch by comparing cluster-wide resources.

#### LLM Investigation Trace (v1.3)

The tables below show the full tool-call sequence and token consumption observed
during a Kind run with `claude-sonnet-4-6` on platform version `1.3.0-rc11`.

**Phase 1 — Root Cause Analysis (4 LLM turns)**

| Turn | Tool calls | Prompt (chars) | What happened |
|------|-----------|----------------|---------------|
| 1 | `todo_write`, `kubectl_get_by_name(StatefulSet/kv-store)`, `kubectl_get_by_kind_in_namespace(Pod)` | 4 521 | Planned investigation; identified 2/3 replicas ready, kv-store-2 Pending |
| 2 | `todo_write` | 4 859 | Updated plan: need PVC and StorageClass details |
| 3 | `kubectl_describe(Pod/kv-store-2)`, `kubectl_get_by_kind_in_namespace(PersistentVolumeClaim)`, `kubectl_events(PVC/data-kv-store-2)`, `kubectl_get_by_kind_in_cluster(StorageClass)`, `kubectl_events(StatefulSet/kv-store)`, `kubectl_events(Pod/kv-store-2)`, `get_namespaced_resource_context(StatefulSet/kv-store)` | 13 636 | Deep investigation: confirmed `broken-storage-class` not found, healthy PVCs use `standard` |
| 4 | `todo_write` → *submit_result (RCA)* | 40 720 | Target: StatefulSet/kv-store — PVC with wrong StorageClass |

**Phase 2 — Workflow Selection (7 LLM turns)**

| Turn | Tool calls | Prompt (chars) | What happened |
|------|-----------|----------------|---------------|
| 1 | `todo_write` | 7 602 | Planned workflow search |
| 2 | `list_available_actions` | 8 038 | Fetched ActionTypes — identified `FixStatefulSetPVC` |
| 3 | `todo_write` | 8 691 | Evaluated: purpose-built for StatefulSet PVC issues |
| 4 | `list_workflows(FixStatefulSetPVC)` | 8 943 | Found `fix-statefulset-pvc-v1` |
| 5 | `todo_write` | 9 996 | Confirmed match |
| 6 | `get_workflow(fix-statefulset-pvc-v1)` | 10 405 | Reviewed full workflow definition |
| 7 | `todo_write` → *submit_result_with_workflow* | 14 476 | Selected fix-statefulset-pvc-v1 (0.95 confidence) |

**Totals**

| Metric | Value |
|--------|-------|
| **Total tokens** | 125 690 (121 066 prompt + 4 624 completion) |
| **Total tool calls** | 19 |
| **LLM turns** | 15 (4 RCA + 7 Workflow + batch calls) |
| **Peak prompt size** | 40 720 chars (RCA submit) |

> **Note**: The RCA phase was highly efficient (4 turns) because turn 3 batched
> 7 parallel tool calls — describing the pod, listing PVCs, checking events for
> 3 resources, querying StorageClasses cluster-wide, and enriching context — all
> in a single LLM round-trip. The peak prompt size (40 720 chars) reflects the
> large amount of cluster context gathered in that batch.

#### 7. Approve the RAR

```bash
RAR=$(kubectl get rar -n kubernaut-system -o jsonpath='{.items[0].metadata.name}')
kubectl patch rar "$RAR" -n kubernaut-system --type=merge --subresource=status \
  -p '{"status":{"decision":"Approved","decidedBy":"operator"}}'
```

#### 8. Watch remediation

The WFE recreates the PVC with the correct StorageClass, deletes the stuck pod, and the pod recovers.

```bash
kubectl get pods -n demo-statefulset -w
kubectl get pvc -n demo-statefulset
```

#### 9. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Cleanup

```bash
./scenarios/statefulset-pvc-failure/cleanup.sh
```

## Pipeline Timeline (OCP observed)

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy StatefulSet (3 replicas) | T+0:00 | — |
| All 3 pods ready | T+0:45 | PVC provisioning + startup |
| Baseline established | T+1:05 | 20 s wait |
| Inject PVC failure | T+1:10 | — |
| kv-store-2 → Pending | T+1:15 | immediate |
| Alert fires | T+4:20 | ~3 min `for:` + scrape |
| RR created | T+4:25 | 5 s |
| AA completes | T+5:55 | ~90 s investigation |
| AwaitingApproval | T+5:55 | `is_sensitive_resource` |
| Operator approves | T+6:30 | manual |
| WFE completes | T+7:20 | ~50 s (recreate PVC + delete pod) |
| EA completes (3/3 ready) | T+9:00 | ~100 s health check |
| **Total** | **~9 min** | (includes manual approval) |

## BDD Specification

```gherkin
Feature: StatefulSet PVC Failure remediation

  Background:
    Given a cluster with Kubernaut services and a real LLM backend
      And StatefulSet "kv-store" has 3 replicas with volumeClaimTemplate "data"
      And all pods are Running and Ready with PVCs Bound

  Scenario: PVC failure detection and remediation
    When the PVC "data-kv-store-2" is replaced with a broken StorageClass
      And the pod "kv-store-2" is recreated but remains Pending
      And the KubeStatefulSetReplicasMismatch alert fires (2/3 ready for 3 min)
    Then the LLM detects stateful=true and diagnoses PVC failure
      And the LLM selects FixStatefulSetPVC (confidence 0.95)
      And the Rego policy requires approval (StatefulSet is sensitive)
      And the operator approves the remediation
      And the WFE recreates "data-kv-store-2" with the correct StorageClass
      And the WFE deletes the stuck pod "kv-store-2"
      And the StatefulSet controller recreates the pod
      And all 3 replicas become Ready
      And the EA confirms successful remediation
```

## Acceptance Criteria

- [ ] StatefulSet deploys with 3 replicas and PVCs Bound
- [ ] PVC injection creates `broken-storage-class` PVC, pod stuck Pending
- [ ] Alert fires within 3-4 minutes
- [ ] LLM detects `stateful: true` and selects `FixStatefulSetPVC` (confidence ≥ 0.9)
- [ ] Rego requires approval (StatefulSet → `is_sensitive_resource`)
- [ ] After approval: WFE recreates PVC with correct StorageClass
- [ ] Pod kv-store-2 recovers to Running
- [ ] All 3 StatefulSet replicas Ready
- [ ] PVC `data-kv-store-2` is Bound (not `broken-storage-class`)
