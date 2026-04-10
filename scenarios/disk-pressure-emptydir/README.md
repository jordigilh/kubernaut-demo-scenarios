# Scenario #324: DiskPressure emptyDir Migration via GitOps + Ansible (Proactive)

> **Environment: OCP only.** This scenario requires privileged node access for constrained
> filesystem setup, AWX/AAP for Ansible playbook execution, and dedicated worker nodes with
> controlled disk capacity. It is not supported on Kind.

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
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics and `node-exporter` |
| HAPI Prometheus | Auto-enabled by `run.sh`, reverted by `cleanup.sh` ([manual enablement](../../docs/prometheus-toolset.md)) |
| AWX/AAP | `scripts/awx-helper.sh` (or `aap-helper.sh` with Red Hat subscription) |
| Gitea + ArgoCD | Deployed via `scenarios/gitops/scripts/setup-gitea.sh` and `scenarios/gitops/scripts/setup-argocd.sh` |
| Gitea webhook | Automated by `run.sh setup` (see [Gitea-ArgoCD Webhook](#gitea-argocd-webhook)) |
| Workflow catalog | `migrate-emptydir-to-pvc-gitops-v1` registered in DataStorage |

### Pre-flight checklist (OCP)

Before running this scenario for the first time on an existing OCP cluster, complete
these steps **in order**. `run.sh all` handles steps 3-5 automatically, but steps 1-2
must be done manually.

```bash
# 1. Configure AWX/AAP (creates aap-api-token, job templates, credentials,
#    patches WE controller with ansible executor). Run once per cluster.
bash scripts/aap-helper.sh            # AAP (Red Hat subscription required)
bash scripts/awx-helper.sh            # or AWX (no license needed)

# 2. Deploy Gitea and ArgoCD (if not already present)
bash scenarios/gitops/scripts/setup-gitea.sh
bash scenarios/gitops/scripts/setup-argocd.sh

# 3. Verify the critical secrets exist
kubectl get secret aap-api-token   -n kubernaut-system      # or awx-api-token
kubectl get secret gitea-repo-creds -n kubernaut-workflows

# 4. Verify the ansible workflow is registered
kubectl get remediationworkflow migrate-emptydir-to-pvc-gitops-v1 -n kubernaut-system

# 5. Verify AAP job template credentials are attached
#    CRITICAL: This is the most common failure point. The AWX/AAP job templates
#    must have both a K8s credential (for cluster access) and a Gitea credential
#    (for GitOps pushes) attached. If they are missing, the Ansible playbook
#    fails immediately with "Could not create API client: Invalid kube-config
#    file. No configuration found."
#
#    After running aap-helper.sh, verify:
kubectl port-forward -n aap svc/kubernaut-controller-service 8080:80 &
AAP_PASS=$(kubectl get secret kubernaut-controller-admin-password -n aap \
  -o jsonpath='{.data.password}' | base64 -d)
# Find the migrate template ID and list its credentials:
TMPL_ID=$(curl -s http://localhost:8080/api/v2/job_templates/ \
  -u "admin:${AAP_PASS}" | python3 -c "
import json,sys; d=json.load(sys.stdin)
for t in d.get('results',[]):
    if 'migrate' in t.get('name','').lower(): print(t['id']); break
")
curl -s "http://localhost:8080/api/v2/job_templates/${TMPL_ID}/credentials/" \
  -u "admin:${AAP_PASS}" | python3 -c "
import json,sys; d=json.load(sys.stdin)
for c in d.get('results',[]):
    print(f'  {c[\"name\"]} (type={c[\"credential_type\"]}, id={c[\"id\"]})')
if not d.get('results'):
    print('  ERROR: No credentials attached! Re-run: bash scripts/aap-helper.sh --configure-only')
"
kill %1 2>/dev/null
```

> **Why the order matters:** The Helm post-install hook seeds workflows at install
> time, but skips `migrate-emptydir-to-pvc-gitops-v1` when `gitea-repo-creds` is
> absent (the workflow declares it as a dependency). Running `aap-helper.sh` before
> the scenario ensures the Ansible engine is registered in WE, and `run.sh setup`
> creates `gitea-repo-creds` and seeds the workflow if it was skipped earlier.

> **Common failure: stale AAP credentials.** If you uninstall/reinstall the Kubernaut
> platform or delete the `aap` namespace, the AAP credential IDs become stale.
> The WE controller creates ephemeral credentials at job launch time, but these
> are cloned from the base credentials on the job template. If the base credentials
> are missing (e.g., after an AAP reinstall), the Ansible playbook fails with a
> kubeconfig error. **Fix:** re-run `bash scripts/aap-helper.sh --configure-only`
> to recreate and re-attach the credentials.

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `migrate-emptydir-to-pvc-gitops-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `migrate-emptydir-to-pvc-gitops-v1-runner` |
| ClusterRoleBinding | `migrate-emptydir-to-pvc-gitops-v1-runner` |

**Permissions**: core nodes (get, list, patch, update), core pods (get, list), core secrets (get, list), core endpoints (get, list), core persistentvolumeclaims (get, list, create, delete), `apps` deployments (get, list), `batch` jobs (get, list, create, delete), `storage.k8s.io` storageclasses (get, list), `argoproj.io` applications (get, list), `kubernaut.ai` workflowexecutions (get, list)

## Automated Run

```bash
# Full run (setup + inject + validate) -- recommended
./scenarios/disk-pressure-emptydir/run.sh all

# Or step-by-step:
./scenarios/disk-pressure-emptydir/run.sh setup    # Deploy manifests, Gitea repo, ArgoCD app
./scenarios/disk-pressure-emptydir/run.sh inject   # Start data growth (runs init.sql then calls stored procedure)
```

> **Note**: The `setup` subcommand explicitly runs `init.sql` via `psql` (Step 5) to
> create the `simulate_data_growth()` stored procedure. The Red Hat sclorg PostgreSQL
> image does not auto-execute `/docker-entrypoint-initdb.d/*.sql` files like the
> upstream Docker image. Always run `setup` before `inject`, or use `run.sh all`
> which handles both steps automatically.

> **Remote execution:** When running scenarios over SSH, use `-tt` to force TTY
> allocation for real-time output: `ssh -tt host "su - user -c './run.sh all'"`

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

The stored procedure `simulate_data_growth(batch_size, iterations, sleep_ms)` must be
called with parameters tuned to the target node's filesystem capacity. Writing too fast
exhausts disk before the pipeline completes; too slow and `predict_linear()` never fires.

Use the helper script to compute the parameters for your environment:

```bash
bash scenarios/disk-pressure-emptydir/compute-inject-params.sh
```

The script reads the node's filesystem stats and prints the computed values along with
a ready-to-paste `kubectl exec` command. It does **not** start the injection — copy the
command it prints and run it when you are ready:

```bash
# Example output (values will differ based on your node's disk capacity):
#   kubectl exec -n demo-diskpressure postgres-emptydir-xxxx -- \
#     psql -U postgres -d postgres -c "CALL simulate_data_growth(128, 29520, 50);" &
```

The rate is auto-tuned so `predict_linear()` fires with ~8 min margin before kubelet eviction,
giving the full pipeline (LLM analysis, RAR approval, AWX dispatch, pg_dump, ArgoCD sync,
pg_restore) enough time to complete before data loss.

> **How it works:** The script targets a write rate that triggers the `PredictedDiskPressure`
> alert at ~4 min while leaving ~8 min before kubelet eviction. It accounts for PostgreSQL's
> ~2x disk amplification (tuple headers, WAL, TOAST) and clamps the rate based on the
> filesystem size to avoid edge cases. See `run_inject()` in `run.sh` for the full algorithm.

### 4. Wait for alert and pipeline

```bash
# PredictedDiskPressure alert fires before kubelet eviction (~2-3 min)

# Query Alertmanager for active alerts (OCP only)
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=PredictedDiskPressure --alertmanager.url=http://localhost:9093

kubectl get rr,sp,aia,rar,wfe,ea,notif -n kubernaut-system -w
```

### 5. Inspect AI Analysis

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

### 6. Approve the remediation (RAR)

The LLM creates a RemediationApprovalRequest. Approve it to proceed:

```bash
RAR=$(kubectl get rar -n kubernaut-system -o name | head -1)
kubectl patch "$RAR" -n kubernaut-system --type merge --subresource=status \
  -p '{"status":{"decision":"Approved","decidedBy":"kube:admin"}}'
```

### 7. Verify remediation

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

The ArgoCD namespace and server label differ by platform:

| | **Kind** | **OCP** |
|---|---|---|
| Namespace | `argocd` | `openshift-gitops` |
| Server label | `app.kubernetes.io/name=argocd-server` | `app.kubernetes.io/name=openshift-gitops-server` |

```bash
# Set the ArgoCD namespace for your platform
ARGOCD_NS="argocd"              # Kind
ARGOCD_NS="openshift-gitops"    # OCP

# 1. Verify Gitea ROOT_URL matches ArgoCD's repoURL
GITEA_POD=$(kubectl get pods -n gitea -l app.kubernetes.io/name=gitea \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n gitea "$GITEA_POD" -- \
  grep ROOT_URL /data/gitea/conf/app.ini
# Expected: ROOT_URL = http://gitea-http.gitea:3000

# 2. Check the ArgoCD secret has the webhook key
kubectl get secret argocd-secret -n "$ARGOCD_NS" \
  -o jsonpath='{.data.webhook\.gitea\.secret}' | base64 -d && echo

# 3. List webhooks on the repo
kubectl exec -n gitea "$GITEA_POD" -- \
  wget -q -O - "http://localhost:3000/api/v1/repos/kubernaut/demo-diskpressure-repo/hooks" \
  --header="Authorization: token <token>" 2>/dev/null | python3 -m json.tool

# 4. Verify ArgoCD receives push events with the correct URL
#    Kind:  -l app.kubernetes.io/name=argocd-server
#    OCP:   -l app.kubernetes.io/name=openshift-gitops-server
kubectl logs -n "$ARGOCD_NS" -l app.kubernetes.io/name=openshift-gitops-server \
  --tail=20 | grep "Received push event"
# Expected URL: http://gitea-http.gitea:3000/kubernaut/demo-diskpressure-repo
```

## Platform Notes

### OCP

The `run.sh` script auto-detects the platform and applies the `overlays/ocp/` kustomization via `get_manifest_dir()`. The overlay:

- Adds `openshift.io/cluster-monitoring: "true"` to the demo namespace
- Swaps `postgres:16-alpine` to `quay.io/sclorg/postgresql-16-c9s` with adjusted env vars and data paths
- Moves the ArgoCD `Application` to the `openshift-gitops` namespace
- Removes the `release` label from `PrometheusRule`

Gitea access uses the OCP Route automatically when available. No manual steps required.

**OCP prerequisites**: OpenShift GitOps operator must be installed from OperatorHub. AWX is deployed via `scripts/awx-helper.sh` (or AAP via `aap-helper.sh` with a Red Hat subscription). See [docs/setup.md](../../docs/setup.md).

**Prometheus RBAC (OCP):** The chart creates the `cluster-monitoring-view`
ClusterRoleBinding for HAPI when `holmesgptApi.prometheus.enabled` and
`ocpMonitoringRbac` are both `true` (default in `helm/kubernaut-ocp-values.yaml`).
`run.sh` also creates the binding as a safety net if it does not exist. For manual
installs without the OCP values file:

```bash
kubectl create clusterrolebinding holmesgpt-monitoring-view \
  --clusterrole=cluster-monitoring-view \
  --serviceaccount=kubernaut-system:holmesgpt-api-sa
```

Without this, HAPI loads the Prometheus toolset but cannot execute queries (401
from Prometheus). The LLM still functions using kubectl-based investigation, but
lacks real-time metrics for disk growth rate analysis.

## Pipeline Timeline (OCP observed, 1.1.0-rc14 on OCP 4.21)

Wall-clock times from a live run on a 4-node OCP 4.21 cluster with a 5 GB constrained
filesystem on the scenario worker node, using Claude Sonnet 4 as the LLM backend.

| Phase | Duration | Notes |
|-------|----------|-------|
| Gitea push + ArgoCD sync | ~30s | Manifests pushed, ArgoCD synced on first attempt |
| Pod readiness | ~3 min | nginx-cache has a 3 min init container for cache warm-up |
| Data growth start | immediate | `simulate_data_growth()` with auto-tuned rate |
| Alert fires | ~4 min | `PredictedDiskPressure` fires via `predict_linear` |
| Gateway -> SP -> AA | ~5s | SP normalizes to `DiskPressure` with `signalMode=proactive` |
| AA completes | ~90s | LLM runs 19 tool calls, identifies PostgreSQL root cause |
| RAR created | immediate | Human approval gate (confidence: 95%) |
| RAR approved | manual | Operator approves remediation |
| AWX playbook | ~5-10 min | cordon -> pg_dump -> git commit (PVC + remove nodeSelector) -> ArgoCD sync -> pg_restore |
| EA verifies | ~7 min | Reduced timing for webhook-based ArgoCD (gitOpsSyncDelay=1m, stabilization=3m, alertDelay=3m) |
| **Total** | **~15-20 min** | End-to-end proactive remediation (includes manual approval) |

### LLM Analysis (OCP observed — correct, rc14)

```
Root cause:    PostgreSQL deployment using unbounded emptyDir storage with
               active data growth simulation causing predictable DiskPressure
Confidence:    95%
Workflow:      MigrateEmptyDirToPVC (migrate-emptydir-to-pvc-gitops-v1)
Rationale:     Perfect match: GitOps-managed PostgreSQL deployment using
               emptyDir storage causing DiskPressure. The workflow migrates
               to PVC via ArgoCD, preventing future disk pressure events.
```

The LLM correctly identified PostgreSQL as the root cause using 19 tool calls:
1. Described the node to assess current disk conditions
2. Listed pods and inspected `postgres-emptydir` pod spec (saw `emptyDir` volume)
3. Read postgres logs (continuous `INSERT` operations from `simulate_data_growth`)
4. Read `postgres-init-sql` ConfigMap (found the growth procedure definition)
5. Resolved resource context (detected `gitOpsManaged=true` via ArgoCD Application)
6. Walked the 3-step workflow discovery protocol -> selected `MigrateEmptyDirToPVC`

> **Note on Prometheus metrics**: `run.sh` enables the `prometheus/metrics` toolset
> but HAPI may not use it in every analysis. In the observed rc14 run, the LLM
> relied on kubectl inspection (pod specs, logs, configmaps) rather than Prometheus
> queries. The Prometheus toolset provides additional signal (disk growth rates via
> `node_filesystem_avail_bytes`) which can help disambiguate when multiple pods
> are actively writing to disk.

### Known Issues

**Fixed in rc14:**

- PrometheusRule `mountpoint` and `instance` selectors incorrect on OCP. Fixed: `run.sh` patches dynamically. See [#100](https://github.com/jordigilh/kubernaut-demo-scenarios/issues/100).
- ArgoCD managed-by label missing on namespace. See [#96](https://github.com/jordigilh/kubernaut-demo-scenarios/issues/96).
- `seed-workflows.sh` skips Ansible workflows even when AWX/AAP is installed. See [#99](https://github.com/jordigilh/kubernaut-demo-scenarios/issues/99).

**Open (upstream):**

- Notification routing config uses `approval_required` instead of `approval`, causing missing Slack notifications. See [kubernaut#571](https://github.com/jordigilh/kubernaut/issues/571).
- EM AlertManager RBAC uses `nonResourceURLs` which OCP's kube-rbac-proxy rejects (403). EA completes as `partial` because alert assessment never succeeds. Safety-net in `enable_prometheus_toolset()` patches the ClusterRole. See [kubernaut#576](https://github.com/jordigilh/kubernaut/issues/576).
- EM DataStorage workflow-started check fails with JSON deserialization error (non-fatal). See [kubernaut#575](https://github.com/jordigilh/kubernaut/issues/575).
- Ansible playbook patches ALL deployment files instead of only the target, and leaves `nodeSelector`/`tolerations` pinning the migrated pod to the constrained node. On OCP with TopoLVM local storage, this causes `ContainerCreating` due to stale CSI driver registration under disk pressure. Fixed upstream. See [kubernaut-test-playbooks#11](https://github.com/jordigilh/kubernaut-test-playbooks/issues/11).

### Post-migration scheduling (WaitForFirstConsumer)

> **Requires:** fixed playbook from [kubernaut-test-playbooks#11](https://github.com/jordigilh/kubernaut-test-playbooks/issues/11) (addressed upstream).

The playbook commits both the PVC manifest and the deployment change (emptyDir->PVC, nodeSelector removal) in a single git push. Because `lvms-vg1` uses `WaitForFirstConsumer` binding mode, the PVC stays Pending until the new pod is scheduled. With the `nodeSelector` and `tolerations` removed, the pod cannot schedule on the tainted constrained node, so it lands on a healthy worker. The PV is provisioned there. This avoids the CSI driver stale-registration issue on the constrained-FS node entirely.

## Troubleshooting

### Ansible playbook fails: "Invalid kube-config file"

```
TASK [Get target deployment]
fatal: [localhost]: FAILED! => {"msg": "Could not create API client:
  Invalid kube-config file. No configuration found."}
```

The AAP job template is missing the K8s credential. This happens when:
- AAP was reinstalled or the `aap` namespace was recreated
- `aap-helper.sh` was not re-run after a platform reinstall
- The WE controller creates ephemeral credentials at launch, but clones them from
  the base credentials on the template — if the base is missing, the clone is empty

**Fix:** `bash scripts/aap-helper.sh --configure-only`

### HAPI pod CrashLoopBackOff after install

Check logs for `FATAL: No LLM credentials found for provider 'vertex_ai'`.
The `llm-credentials` secret requires specific keys depending on the provider.
For Vertex AI, it needs `VERTEXAI_PROJECT`, `VERTEXAI_LOCATION`,
`GOOGLE_APPLICATION_CREDENTIALS` (mount path), and `application_default_credentials.json`
(file content). See `helm/llm-credentials/vertex-ai-example.yaml`.

### Slack notifications not received

Even if `NotificationRequest` shows `Sent`, check the `notification-routing-config`
ConfigMap. The auto-generated routing may use `type: approval_required` while the RO
emits `type: approval`. Patch the routing or set `slack-alerts` as the default receiver.
See [kubernaut#571](https://github.com/jordigilh/kubernaut/issues/571).

### Alert never fires

Verify the `PrometheusRule` expression matches the target node. On OCP, `run.sh`
patches the rule with the correct `mountpoint` and `instance` values. If the
constrained filesystem is not mounted, the `predict_linear` has no data to work with.

```bash
kubectl get prometheusrule demo-diskpressure-rules -n demo-diskpressure \
  -o jsonpath='{.spec.groups[0].rules[0].expr}'
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
