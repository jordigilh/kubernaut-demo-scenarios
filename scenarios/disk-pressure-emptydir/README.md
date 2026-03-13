# Scenario #324: DiskPressure emptyDir Migration via GitOps + Ansible

## Overview

Demonstrates Kubernaut's flagship enterprise remediation pipeline. A PostgreSQL database
running on ephemeral `emptyDir` storage fills disk until the node reports `DiskPressure`.
The LLM detects the emptyDir anti-pattern, triggers a human approval gate (RAR), and
upon approval, executes an Ansible/AWX playbook that:

1. Backs up the database via `pg_dump`
2. Commits a PVC migration (emptyDir -> PersistentVolumeClaim) to Git
3. ArgoCD syncs the migration
4. Restores the database to the new PVC-backed instance

**Signal**: `KubeNodeDiskPressure` -- node DiskPressure condition for >1 min
**Root cause**: PostgreSQL on emptyDir filling ephemeral storage
**Remediation**: `migrate-emptydir-to-pvc-gitops-v1` (Ansible engine via AWX)

## Signal Flow

```
kube_node_status_condition{condition="DiskPressure"} == 1 for 1m
  -> KubeNodeDiskPressure alert
  -> Gateway -> SP -> AA (HAPI + LLM)
  -> LLM detects emptyDir anti-pattern + gitOpsTool label
  -> Selects MigrateEmptyDirToPVC workflow
  -> RO creates RAR (human approval gate)
  -> Upon approval: WE (Ansible/AWX) runs playbook
  -> Backup -> Git commit -> ArgoCD sync -> Restore
  -> EM verifies DiskPressure resolved + data intact
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Kind cluster | `kind-config-diskpressure.yaml` (lowered kubelet eviction thresholds) |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics |
| AWX | Deployed via `scripts/awx-helper.sh` |
| Gitea + ArgoCD | Deployed via `scripts/setup-gitea.sh` and `scripts/setup-argocd.sh` |
| Workflow catalog | `migrate-emptydir-to-pvc-gitops-v1` registered in DataStorage |

## Automated Run

```bash
# Full run (setup + inject + validate)
./scenarios/disk-pressure-emptydir/run.sh

# Or step-by-step:
./scenarios/disk-pressure-emptydir/run.sh setup
./scenarios/disk-pressure-emptydir/run.sh inject
```

## Manual Step-by-Step

### 1. Deploy scenario resources

```bash
kubectl apply -k scenarios/disk-pressure-emptydir/manifests/
kubectl wait --for=condition=Available deployment/postgres-emptydir \
  -n demo-diskpressure --timeout=120s
```

### 2. Verify healthy state

```bash
kubectl get pods -n demo-diskpressure
kubectl exec -n demo-diskpressure deploy/postgres-emptydir -- pg_isready -U postgres
```

### 3. Inject disk pressure

```bash
# Connect to the PostgreSQL pod and run the data growth procedure
POD=$(kubectl get pod -n demo-diskpressure -l app=postgres-emptydir -o name | head -1)
kubectl exec -n demo-diskpressure "$POD" -- \
  psql -U postgres -c "CALL simulate_data_growth(500, 200, 50);" &
```

The stored procedure generates ~1 KB per row, 500 rows per batch, 200 iterations with
50ms sleep between batches. This fills the emptyDir volume until DiskPressure is triggered.

### 4. Wait for alert and pipeline

```bash
# DiskPressure alert fires after ~1 min of node condition
kubectl get rr,sp,aa,rar,we,ea -n kubernaut-system -w
```

### 5. Approve the remediation (RAR)

The LLM creates a RemediationApprovalRequest. Approve it to proceed:

```bash
RAR=$(kubectl get rar -n kubernaut-system -o name | head -1)
kubectl patch "$RAR" -n kubernaut-system --type merge \
  -p '{"spec":{"decision":"approved"}}'
```

### 6. Verify remediation

```bash
# DiskPressure condition should resolve
kubectl get nodes -o custom-columns=NAME:.metadata.name,DISK_PRESSURE:.status.conditions[3].status

# PVC should exist and be bound
kubectl get pvc -n demo-diskpressure

# Database data should be intact
kubectl exec -n demo-diskpressure deploy/postgres-emptydir -- \
  psql -U postgres -c "SELECT count(*) FROM events;"
```

## Cleanup

```bash
./scenarios/disk-pressure-emptydir/cleanup.sh
```

## BDD Specification

```gherkin
Feature: DiskPressure emptyDir Migration via GitOps + Ansible

  Scenario: PostgreSQL on emptyDir triggers DiskPressure and GitOps migration
    Given a Kind cluster with lowered kubelet eviction thresholds
      And AWX, Gitea, and ArgoCD are deployed
      And the "migrate-emptydir-to-pvc-gitops-v1" workflow is registered
      And a PostgreSQL deployment "postgres-emptydir" runs on emptyDir storage

    When the simulate_data_growth procedure fills the emptyDir volume
      And the node reports DiskPressure condition
      And the KubeNodeDiskPressure alert fires after 1 minute

    Then the LLM detects the emptyDir anti-pattern and gitOpsTool label
      And selects MigrateEmptyDirToPVC workflow
      And RO creates a RemediationApprovalRequest (human gate)
      And upon approval, WE dispatches the Ansible playbook via AWX
      And the playbook backs up the database via pg_dump
      And the playbook commits emptyDir-to-PVC migration to Git
      And ArgoCD syncs the migration to the cluster
      And the playbook restores the database to the PVC-backed instance
      And EM verifies DiskPressure resolved and data is intact
```

## Acceptance Criteria

- [ ] PostgreSQL runs on emptyDir and grows data until DiskPressure
- [ ] KubeNodeDiskPressure alert fires
- [ ] LLM identifies emptyDir anti-pattern as root cause
- [ ] RAR is created for human approval
- [ ] Ansible/AWX playbook executes after approval
- [ ] Database backup is created via pg_dump
- [ ] PVC migration is committed to Git
- [ ] ArgoCD syncs the migration
- [ ] Database is restored to PVC-backed storage
- [ ] DiskPressure condition resolves
- [ ] EM confirms data integrity
