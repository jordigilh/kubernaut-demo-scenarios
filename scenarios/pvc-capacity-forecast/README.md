# Scenario: PVC Capacity Forecast -- Proactive PVC Expansion

> **Environment: OCP only.** Requires a StorageClass with `allowVolumeExpansion: true`
> and kubelet volume stats metrics (standard on OCP).

## Overview

Proof-of-concept for **Kubernaut as the action layer for RHACM capacity forecasting**.
Demonstrates the end-to-end pipeline that closes the gap between capacity detection and
automated response:

1. **Signal intake**: `predict_linear` forecasting alert fires when PVC exhaustion is
   projected within 1 hour
2. **Investigation**: The LLM queries Prometheus for growth rate/pattern, checks
   StorageClass expansion support, identifies the root cause of storage growth
3. **Remediation selection**: Based on investigation, selects `ExpandPersistentVolumeClaim`
4. **Execution**: Patches PVC storage request to a larger size
5. **Effectiveness verification**: Confirms PVC capacity increased and runway extended

See: [Kubernaut as the Action Layer for RHACM Capacity Forecasting](https://gist.github.com/jordigilh/f394884cfec234cddb7289cb9e5c5bb2)

## ITIL Classification

| Field | Value |
|-------|-------|
| **ITIL Level** | L3 -- Capacity Management |
| **Category** | Proactive / Predictive |
| **Signal** | `PVRunwayShort` (predict_linear) |
| **ActionType** | `ExpandPersistentVolumeClaim` |
| **Workflow** | `expand-pvc-v1` |
| **Status** | IN PROGRESS |

## Architecture

```
data-writer sidecar          Prometheus                    Kubernaut
   (fills PVC at ~5MB/min)      (kubelet_volume_stats)       (investigation + remediation)
          |                         |                              |
          v                         v                              v
   PVC usage grows  -->  predict_linear fires  -->  PVRunwayShort alert
                         PVRunwayShort alert         --> RemediationRequest
                                                     --> AI Analysis (investigate WHY)
                                                     --> ExpandPersistentVolumeClaim
                                                     --> PVC patched to 2x size
                                                     --> EffectivenessAssessment
```

## Signal

The `PVRunwayShort` alert fires when `predict_linear` projects that the PVC will exhaust
its capacity within 1 hour based on the last 5 minutes of growth data:

```promql
predict_linear(
  kubelet_volume_stats_used_bytes{
    namespace="demo-pvc-forecast",
    persistentvolumeclaim="data-service-data"
  }[5m], 3600
)
>
kubelet_volume_stats_capacity_bytes{
  namespace="demo-pvc-forecast",
  persistentvolumeclaim="data-service-data"
}
```

## Workload

- **Deployment `data-service`**: PostgreSQL with a `data-writer` sidecar that writes
  ~5MB/min to the PVC, simulating post-migration WAL/data growth.
- **PVC `data-service-data`**: 512Mi on `lvms-vg1` (topolvm, thin-provisioned, xfs).

## Remediation

The `expand-pvc-v1` workflow:

1. **Validates** the PVC exists and its StorageClass supports expansion
2. **Calculates** new size (2x current)
3. **Patches** the PVC `spec.resources.requests.storage`
4. **Verifies** the CSI driver completes the resize (polls `status.capacity.storage`)

## Validation

| Assertion | Expected |
|-----------|----------|
| RR phase | Completed |
| RR outcome | Remediated or Inconclusive |
| SP phase | Completed |
| AA phase | Completed |
| AA selected workflow | expand-pvc |
| AA root cause | Present (investigation happened) |
| AA remediation target | Present |
| WFE phase | Completed |
| PVC capacity | Increased from 512Mi |

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | OCP with Kubernaut services deployed |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | Kubelet volume stats metrics (`kubelet_volume_stats_used_bytes`, `kubelet_volume_stats_capacity_bytes`) -- standard on OCP |
| StorageClass | At least one StorageClass with `allowVolumeExpansion: true` and a CSI driver that supports `ControllerExpandVolume` + `NodeExpandVolume` |
| Filesystem | PVC filesystem must support online resize (`xfs` or `ext4`) |
| Workflow catalog | `expand-pvc-v1` registered in DataStorage |
| ActionType | `ExpandPersistentVolumeClaim` registered in kubernaut-system |
| KA Prometheus | Auto-enabled by `run.sh`, reverted by `cleanup.sh` ([manual enablement](../../docs/prometheus-toolset.md)) |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `expand-pvc-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `expand-pvc-v1-runner` |
| ClusterRoleBinding | `expand-pvc-v1-runner` |

**Permissions**:

| API group | Resource | Verbs |
|-----------|----------|-------|
| core | persistentvolumeclaims | get, list, patch, update |
| `storage.k8s.io` | storageclasses | get, list |
| core | persistentvolumes | get, list |
| core | events | get, list |

### Pre-flight checklist

Before running this scenario, verify the following:

```bash
# 1. Verify a StorageClass supports volume expansion
kubectl get sc -o custom-columns='NAME:.metadata.name,EXPANSION:.allowVolumeExpansion' | grep true

# 2. Verify kubelet volume stats metrics are available
#    (query Prometheus directly or via Thanos)
#    Expected: at least one result with namespace, persistentvolumeclaim labels
kubectl exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=kubelet_volume_stats_used_bytes' \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'{len(r[\"data\"][\"result\"])} PVCs reporting')"

# 3. Verify the ActionType and workflow are registered
kubectl get actiontype expand-pvc -n kubernaut-system
kubectl get remediationworkflow expand-pvc-v1 -n kubernaut-system

# 4. Verify the workflow runner SA exists
kubectl get sa expand-pvc-v1-runner -n kubernaut-workflows
```

### Tested StorageClass configurations

| StorageClass | Provisioner | Filesystem | Online Resize | Status |
|--------------|-------------|------------|---------------|--------|
| `lvms-vg1` | `topolvm.io` (LVM Storage) | xfs | Yes | Verified |

## Usage

```bash
# Run with auto-approval
./scenarios/pvc-capacity-forecast/run.sh --auto-approve

# Run with manual approval gate
./scenarios/pvc-capacity-forecast/run.sh --interactive

# Cleanup
./scenarios/pvc-capacity-forecast/cleanup.sh
```
