# Scenario #137: StatefulSet PVC Failure — Stateful Workload Remediation

## Overview

Demonstrates Kubernaut detecting a StatefulSet-based workload with PVC disruption
causing a pod stuck in Pending, and performing automatic remediation by recreating the
missing PVC with the correct StorageClass and deleting the stuck pod to allow
rescheduling.

The LLM correctly detects `stateful: true` from the ownership chain, diagnoses the
PVC failure (non-existent StorageClass), and selects the `FixStatefulSetPVC` workflow.

**Signal**: `KubeStatefulSetReplicasMismatch` — ready replicas < desired for >3 min
**Root cause**: PVC `data-kv-store-2` references non-existent StorageClass `broken-storage-class`
**Remediation**: `fix-statefulset-pvc-v1` — recreates PVC with correct SC, deletes stuck pod

## Signal Flow

```
kube_statefulset_status_replicas_ready < kube_statefulset_status_replicas for 3m
→ KubeStatefulSetReplicasMismatch alert
→ Gateway → SP → AA (HAPI + LLM)
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
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics |
| StorageClass | Cluster default (Kind: `standard`, OCP: `ocs-storagecluster-ceph-rbd`) |
| Workflow | `fix-statefulset-pvc-v1` (shipped with demo content) |

## Automated Run

```bash
./scenarios/statefulset-pvc-failure/run.sh
```

Options:
- `--interactive` — pause at approval gate for manual approve/reject
- `--no-validate` — skip the automated validation pipeline

> Because StatefulSets always require approval, `--interactive` is recommended.

## Manual Step-by-Step

```bash
# 1. Deploy
kubectl apply -k scenarios/statefulset-pvc-failure/manifests       # Kind
kubectl apply -k scenarios/statefulset-pvc-failure/overlays/ocp    # OCP

# 2. Wait for StatefulSet (3 replicas)
kubectl rollout status sts/kv-store -n demo-statefulset --timeout=180s

# 3. Inject PVC failure
bash scenarios/statefulset-pvc-failure/inject-pvc-issue.sh
# kv-store-2 → Pending (broken-storage-class)

# 4. Wait for alert (~3 min)
# 5. Monitor pipeline
kubectl get rr -n kubernaut-system -w
# Expect: Analyzing → AwaitingApproval

# 6. Approve the RAR
RAR=$(kubectl get rar -n kubernaut-system -o jsonpath='{.items[0].metadata.name}')
kubectl patch rar "$RAR" -n kubernaut-system --type=merge --subresource=status \
  -p '{"status":{"decision":"Approved","decidedBy":"operator"}}'

# 7. Watch remediation
# WFE recreates PVC with correct SC → deletes stuck pod → pod recovers
kubectl get pods -n demo-statefulset -w
kubectl get pvc -n demo-statefulset
```

## Platform Notes

### OCP

The `run.sh` script auto-detects the platform and applies the `overlays/ocp/` kustomization via `get_manifest_dir()`. The overlay:

- Adds `openshift.io/cluster-monitoring: "true"` to the demo namespace
- Swaps `nginx:1.27-alpine` to `nginxinc/nginx-unprivileged:1.27-alpine` on the StatefulSet
- Removes the `release` label from `PrometheusRule`

No manual steps required.

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
