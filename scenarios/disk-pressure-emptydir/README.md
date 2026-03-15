# Scenario #324: DiskPressure emptyDir Migration via GitOps + Ansible (Proactive)

## Overview

Demonstrates Kubernaut's flagship enterprise **proactive** remediation pipeline. A PostgreSQL
database running on ephemeral `emptyDir` storage fills disk. A `predict_linear()` alert
detects the trend and fires `PredictedDiskPressure` **before** the kubelet triggers eviction.
The Signal Processor classifies this as a proactive signal (BR-SP-106), normalizes it to
`DiskPressure`, and the LLM uses a proactive investigation prompt ("predict & prevent").
Upon approval, an Ansible/AWX playbook:

1. Backs up the database via `pg_dump` (pod still running -- proactive window)
2. Commits a PVC migration (emptyDir -> PersistentVolumeClaim) to Git
3. ArgoCD syncs the migration
4. Restores the database to the new PVC-backed instance

**Signal**: `PredictedDiskPressure` -- proactive, `predict_linear()` projects disk exhaustion
**SP normalization**: `PredictedDiskPressure` -> `DiskPressure` (`signalMode=proactive`)
**Root cause**: PostgreSQL on emptyDir filling ephemeral storage
**Remediation**: `migrate-emptydir-to-pvc-gitops-v1` (Ansible engine via AWX)

## Signal Flow

```
predict_linear(node_filesystem_avail_bytes[3m], 1200) < 0  for 1m
  -> PredictedDiskPressure alert (proactive)
  -> Gateway -> SP (normalizes to DiskPressure, signalMode=proactive)
  -> AA (HAPI + LLM, proactive prompt: "predict & prevent")
  -> LLM detects emptyDir anti-pattern + gitOpsTool label
  -> Selects MigrateEmptyDirToPVC workflow
  -> RO creates RAR (human approval gate)
  -> Upon approval: WE (Ansible/AWX) runs playbook
  -> Backup (live pg_dump) -> Git commit -> ArgoCD sync (via webhook) -> Restore
  -> EM verifies DiskPressure never materialized + data intact
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| OCP cluster | Dedicated stress-worker node (~25 GB disk, label `scenario=disk-pressure`) |
| Kind cluster | `kind-config-diskpressure.yaml` (lowered kubelet eviction thresholds) |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics and `node-exporter` |
| AAP/AWX | AAP on OCP, AWX on Kind (deploy via `scripts/aap-helper.sh`) |
| Gitea + ArgoCD | Deployed via `scripts/setup-gitea.sh` and `scripts/setup-argocd.sh` |
| Gitea webhook | Automated by `run.sh setup` (see [Gitea-ArgoCD Webhook](#gitea-argocd-webhook)) |
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

The stored procedure parameters (batch_size, iterations, sleep_ms) are computed dynamically
by `run.sh inject` based on the target node's filesystem capacity (see `run_inject()`).
The rate is auto-tuned so `predict_linear()` fires with ~8 min margin before kubelet eviction,
giving the full pipeline (LLM analysis, RAR approval, AWX dispatch, pg_dump, ArgoCD sync,
pg_restore) enough time to complete before data loss.

### 4. Wait for alert and pipeline

```bash
# PredictedDiskPressure alert fires before kubelet eviction (~2-3 min)
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
# DiskPressure should never have materialized (proactive remediation)
kubectl get nodes -o custom-columns=NAME:.metadata.name,DISK_PRESSURE:.status.conditions[3].status

# PVC should exist and be bound
kubectl get pvc -n demo-diskpressure

# Database data should be intact
kubectl exec -n demo-diskpressure deploy/postgres-emptydir -- \
  psql -U postgres -c "SELECT count(*) FROM events;"
```

## Gitea-ArgoCD Webhook

The remediation playbook pushes a PVC migration commit to Gitea. For ArgoCD to pick
up the change immediately (rather than waiting for its polling interval), a **Gitea
webhook** must notify ArgoCD on every push.

**`run.sh setup` configures this automatically** via the `setup_gitea_argocd_webhook`
function. It is idempotent and safe to run multiple times.

What it does:

1. **Gitea ROOT_URL alignment**: sets Gitea's `ROOT_URL` to
   `http://gitea-http.gitea:3000` (the in-cluster service URL). Gitea embeds
   `ROOT_URL` in webhook payloads and ArgoCD matches that URL against
   `Application.spec.source.repoURL`. If these differ (e.g. Gitea defaults to
   `http://git.example.com`), ArgoCD receives the push event but silently
   ignores it because it cannot match the repo to any Application.
2. **TLS skip**: configures `SKIP_TLS_VERIFY=true` and `ALLOWED_HOST_LIST=*`
   in Gitea's `[webhook]` section so it can reach ArgoCD's in-cluster HTTPS
   endpoint without certificate errors.
3. **ArgoCD secret**: ensures `webhook.gitea.secret` exists in `argocd-secret`
   (generates a random hex secret if absent).
4. **Gitea webhook**: deletes any stale webhook from prior runs, then creates
   a fresh one on the `demo-diskpressure-repo` repository with the current
   secret. The webhook posts push events to the ArgoCD server's in-cluster
   endpoint (`https://openshift-gitops-server.openshift-gitops.svc/api/webhook`
   on OCP, or `https://argocd-server.argocd.svc/api/webhook` on Kind).

No extra RBAC is required -- the webhook is an HTTP call from Gitea to ArgoCD,
not a Kubernetes API operation.

### Manual verification

```bash
# 1. Verify Gitea ROOT_URL matches ArgoCD's repoURL
GITEA_POD=$(kubectl get pods -n gitea -l app.kubernetes.io/name=gitea \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n gitea "$GITEA_POD" -- \
  grep ROOT_URL /data/gitea/conf/app.ini
# Expected: ROOT_URL = http://gitea-http.gitea:3000

# 2. Check the ArgoCD secret has the webhook key
kubectl get secret argocd-secret -n openshift-gitops \
  -o jsonpath='{.data.webhook\.gitea\.secret}' | base64 -d && echo

# 3. List webhooks on the repo
kubectl exec -n gitea "$GITEA_POD" -- \
  wget -q -O - "http://localhost:3000/api/v1/repos/kubernaut/demo-diskpressure-repo/hooks" \
  --header="Authorization: token <token>" 2>/dev/null | python3 -m json.tool

# 4. Verify ArgoCD receives push events with the correct URL
kubectl logs -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-server \
  --tail=20 | grep "Received push event"
# Expected URL: http://gitea-http.gitea:3000/kubernaut/demo-diskpressure-repo
```

## Cleanup

```bash
./scenarios/disk-pressure-emptydir/cleanup.sh
```

## BDD Specification

```gherkin
Feature: DiskPressure emptyDir Migration via GitOps + Ansible (Proactive)

  Scenario: PostgreSQL on emptyDir triggers PredictedDiskPressure and GitOps migration
    Given an OCP cluster with stress-worker nodes (or Kind with lowered eviction thresholds)
      And AWX, Gitea, and ArgoCD are deployed
      And the "migrate-emptydir-to-pvc-gitops-v1" workflow is registered
      And a PostgreSQL deployment "postgres-emptydir" runs on emptyDir storage

    When the simulate_data_growth procedure fills the emptyDir volume
      And predict_linear() detects disk exhaustion trend
      And the PredictedDiskPressure alert fires (proactive, before eviction)

    Then SP classifies signal as proactive (signalMode=proactive, signalName=DiskPressure)
      And HAPI uses proactive investigation prompt ("predict & prevent")
      And the LLM detects the emptyDir anti-pattern and gitOpsTool label
      And the LLM selects MigrateEmptyDirToPVC workflow
      And RO creates a RemediationApprovalRequest (human gate)
      And upon approval, WE dispatches the Ansible playbook via AWX
      And the playbook backs up the database via live pg_dump (pod still running)
      And the playbook commits emptyDir-to-PVC migration to Git
      And ArgoCD syncs the migration to the cluster
      And the playbook restores the database to the PVC-backed instance
      And EM verifies DiskPressure never materialized and data is intact
```

## Acceptance Criteria

- [ ] PostgreSQL runs on emptyDir and grows data steadily
- [ ] PredictedDiskPressure alert fires (proactive, before kubelet eviction)
- [ ] SP classifies signal as proactive (signalMode=proactive)
- [ ] HAPI uses proactive investigation prompt
- [ ] LLM identifies emptyDir anti-pattern as root cause
- [ ] RAR is created for human approval
- [ ] Ansible/AWX playbook executes after approval
- [ ] Database backup is created via live pg_dump (pod still running)
- [ ] PVC migration is committed to Git
- [ ] ArgoCD syncs the migration
- [ ] Database is restored to PVC-backed storage
- [ ] DiskPressure never materializes (proactive prevention)
- [ ] EM confirms data integrity
