# Scenario #125: GitOps Drift Remediation (ArgoCD + Gitea)

## Overview

Demonstrates Kubernaut remediating a broken ConfigMap in a GitOps-managed environment.
The LLM traces a pod crash signal to a ConfigMap root cause (signal != RCA resource)
and selects `git revert` over `kubectl rollback` because the environment is GitOps-managed.

**Key differentiator**: Signal resource (crashing Pod) differs from RCA resource (broken ConfigMap).
The LLM must choose the GitOps-aware remediation path.

## Prerequisites

| Component | Kind | OCP |
|-----------|------|-----|
| Cluster | `overlays/kind/kind-cluster-config.yaml` | OpenShift 4.x cluster |
| Container runtime | Podman | — (provided by OCP) |
| Gitea | Deployed via `scenarios/gitops/scripts/setup-gitea.sh` | Same (adds OCP-compatible securityContext) |
| ArgoCD | Full install via `scenarios/gitops/scripts/setup-argocd.sh` (includes server + Gitea webhook) | OpenShift GitOps operator (script skips install, provisions credentials only) |
| Memory budget | ~6.2GB total (4.6GB base + 1.6GB GitOps infra) | N/A (cluster-managed) |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `git-revert-v2-runner` (in `kubernaut-workflows`) |
| ClusterRole | `git-revert-v2-runner` |
| ClusterRoleBinding | `git-revert-v2-runner` |

**Permissions**:

| API group | Resources | Verbs |
|-----------|-----------|-------|
| argoproj.io | applications | get, list |
| core | pods | get, list |

## BDD Specification

```gherkin
Feature: GitOps drift remediation via git revert

  Scenario: Broken ConfigMap causes CrashLoopBackOff in GitOps environment
    Given ArgoCD manages Deployment "web-frontend" in namespace "demo-gitops"
      And the Deployment mounts ConfigMap "app-config" as /etc/demo-http-server/config.yaml
      And the Gitea repository contains healthy manifests synced by ArgoCD
      And all pods are Running and Ready

    When a bad commit is pushed to Gitea changing ConfigMap "app-config" to contain an invalid_directive
      And ArgoCD syncs the broken ConfigMap to the cluster
      And pods restart and enter CrashLoopBackOff

    Then Prometheus fires "KubePodCrashLooping" alert for namespace "demo-gitops"
      And Gateway creates a RemediationRequest
      And Signal Processing enriches with namespace labels (environment=staging, criticality=high)
      And KA LabelDetector detects "gitOpsManaged=true" from ArgoCD annotations
      And the LLM traces the crash to ConfigMap "app-config" (RCA resource != signal resource)
      And the LLM selects "GitRevertCommit" workflow (not "RollbackDeployment")
      And Remediation Orchestrator creates WorkflowExecution
      And the WE Job clones the Gitea repo and runs "git revert HEAD"
      And ArgoCD syncs the reverted ConfigMap back to the cluster
      And Effectiveness Monitor verifies pods are Running and Ready
```

## Acceptance Criteria

- [ ] Gitea + ArgoCD deployed and managing `demo-gitops` namespace
- [ ] Bad ConfigMap commit causes CrashLoopBackOff
- [ ] SP enriches signal with business classification from namespace labels
- [ ] KA detects `gitOpsManaged=true` from ArgoCD annotations (DD-HAPI-018)
- [ ] LLM identifies ConfigMap as root cause (signal != RCA)
- [ ] LLM selects `GitRevertCommit` workflow over `RollbackDeployment`
- [ ] WE Job performs `git revert` in Gitea repository
- [ ] ArgoCD auto-syncs the reverted state
- [ ] EM verifies Deployment health restored (metricsScore > 0 via ServiceMonitor)
- [ ] Full pipeline: Gateway -> RO -> SP -> AA -> WE -> EM

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
./scenarios/gitops-drift/run.sh
```

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/gitops-drift/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Install GitOps Infrastructure

```bash
# Install Gitea (creates repo with healthy manifests)
./scenarios/gitops/scripts/setup-gitea.sh

# Install ArgoCD (registers Gitea repo credentials + Gitea webhook on Kind)
./scenarios/gitops/scripts/setup-argocd.sh
```

#### 2. Register Gitea Webhook (if missing)

`setup-argocd.sh` creates the webhook on Kind. On OCP (or if the repo was
recreated), register it manually so pushes trigger immediate ArgoCD sync:

```bash
# Port-forward to Gitea
kubectl port-forward -n gitea svc/gitea-http 3031:3000 &

ARGOCD_SVC=argocd-server
ARGOCD_NS=argocd

curl -s -X POST "http://kubernaut:kubernaut123@localhost:3031/api/v1/repos/kubernaut/demo-gitops-repo/hooks" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"gitea\",
    \"active\": true,
    \"config\": {
      \"url\": \"http://${ARGOCD_SVC}.${ARGOCD_NS}.svc.cluster.local/api/webhook\",
      \"content_type\": \"json\"
    },
    \"events\": [\"push\"]
  }"

# Kill the port-forward
kill %1 2>/dev/null
```

<details>
<summary><strong>OCP</strong></summary>

```bash
# Port-forward to Gitea
kubectl port-forward -n gitea svc/gitea-http 3031:3000 &

ARGOCD_SVC=openshift-gitops-server
ARGOCD_NS=openshift-gitops

curl -s -X POST "http://kubernaut:kubernaut123@localhost:3031/api/v1/repos/kubernaut/demo-gitops-repo/hooks" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"gitea\",
    \"active\": true,
    \"config\": {
      \"url\": \"http://${ARGOCD_SVC}.${ARGOCD_NS}.svc.cluster.local/api/webhook\",
      \"content_type\": \"json\"
    },
    \"events\": [\"push\"]
  }"

# Kill the port-forward
kill %1 2>/dev/null
```

</details>

#### 3. Deploy Scenario Resources

Apply the full kustomization (namespace, PrometheusRule, ServiceMonitor,
ArgoCD Application, etc.) in one step. On OCP, use the overlay so the
ArgoCD Application targets `openshift-gitops` and the namespace gets the
cluster-monitoring label:

```bash
kubectl apply -k scenarios/gitops-drift/manifests

# Wait for ArgoCD to sync and the deployment to become available
kubectl wait --for=condition=Available deployment/web-frontend \
  -n demo-gitops --timeout=120s
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/gitops-drift/overlays/ocp

kubectl wait --for=condition=Available deployment/web-frontend \
  -n demo-gitops --timeout=120s
```

</details>

#### 4. Verify Healthy State

```bash
kubectl get pods -n demo-gitops
# NAME                            READY   STATUS    RESTARTS   AGE
# web-frontend-xxx-yyy            1/1     Running   0          30s
```

#### 5. Inject Failure

> **Important**: The injected `configmap.yaml` must remain valid YAML. If ArgoCD
> cannot parse the manifest (e.g. tab characters, broken indentation), it will
> reject the sync entirely and the deployment will never update — no crash, no
> alert, no pipeline.

```bash
# Port-forward to Gitea
kubectl port-forward -n gitea svc/gitea-http 3031:3000 &

# Clone the repo
git clone http://kubernaut:kubernaut123@localhost:3031/kubernaut/demo-gitops-repo.git /tmp/gitops-break
cd /tmp/gitops-break

# Overwrite configmap.yaml with an invalid_directive (demo-http-server detects it and exits)
cat > manifests/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: demo-gitops
  labels:
    app: web-frontend
data:
  config.yaml: |
    port: 8080
    # INVALID: demo-http-server detects this and exits with [emerg]
    invalid_directive: true
    routes:
      - path: /
        status: 200
        body: 'healthy'
      - path: /healthz
        status: 200
        body: 'ok'
EOF

# Force a pod rollout by adding an annotation to the deployment
cat > manifests/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-frontend
  namespace: demo-gitops
  labels:
    app: web-frontend
    kubernaut.ai/managed: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-frontend
  template:
    metadata:
      labels:
        app: web-frontend
        kubernaut.ai/managed: "true"
      annotations:
        kubernaut.ai/config-version: "broken"
    spec:
      containers:
      - name: web-frontend
        image: quay.io/kubernaut-cicd/demo-http-server:1.0.0
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: CONFIG_PATH
          value: /etc/demo-http-server/config.yaml
        volumeMounts:
        - name: config
          mountPath: /etc/demo-http-server/config.yaml
          subPath: config.yaml
        resources:
          requests:
            memory: "32Mi"
            cpu: "10m"
          limits:
            memory: "64Mi"
            cpu: "50m"
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 3
          periodSeconds: 5
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 3
      volumes:
      - name: config
        configMap:
          name: app-config
EOF

git add .
git commit -m "chore: update app config (broken value)"
git push origin main

# The Gitea webhook notifies ArgoCD immediately; sync happens within seconds
```

#### 6. Observe Pipeline

```bash
# Watch pods crash
kubectl get pods -n demo-gitops -w
```

Query Alertmanager for active alerts:

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert query alertname=KubePodCrashLooping --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=KubePodCrashLooping --alertmanager.url=http://localhost:9093
```

</details>

```bash
# Watch Kubernaut CRDs
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

#### 7. Inspect AI Analysis

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
```

#### Expected LLM Reasoning (v1.3 baseline)

When Kubernaut's AI analysis processes this scenario, the LLM typically reasons as follows:

| Field | Expected Value |
|-------|---------------|
| **Root Cause** | Pod web-frontend is crash-looping (exit code 1, 4 restarts) due to an invalid directive `invalid_directive: true` in the app-config ConfigMap mounted at `/etc/demo-http-server/config.yaml`. The bad ConfigMap was synced to the cluster by ArgoCD from the GitOps repository, making the Git source the authoritative root cause. |
| **Severity** | critical |
| **Target Resource** | ConfigMap/app-config (ns: demo-gitops) |
| **Workflow Selected** | git-revert-v2 (`GitRevertCommit`) |
| **Confidence** | 0.97 |
| **Approval** | not required (staging, high confidence) |
| **Alternative** | hotfix-config-v1 (`PatchConfiguration`) — rejected at 0.35 confidence: "explicitly states do not use when environment is GitOps-managed; in-place patch will be overwritten by next ArgoCD sync" |

**Key Reasoning Chain:**

1. Describes crashing Pod, reads events and previous logs — identifies exit code 1 and `[emerg] invalid directive found`.
2. Fetches ConfigMap `app-config` via `kubectl_get_by_name` — confirms `invalid_directive: true`.
3. Enriches with `get_namespaced_resource_context` — detects `gitOpsManaged=true`, `gitOpsTool=argocd`.
4. Submits RCA: ConfigMap/app-config is the root cause (signal resource Pod != RCA resource ConfigMap).
5. Lists available actions, queries `GitRevertCommit` and `PatchConfiguration` workflows.
6. Selects `git-revert-v2` at 97% confidence — "only a git revert permanently fixes the root cause in the source of truth".

> **Why this matters**: Shows the LLM's critical ability to (a) trace the crash from a Pod signal to a ConfigMap root cause (cross-resource RCA), (b) detect GitOps management from ArgoCD annotations, and (c) reject in-place patching in favour of a durable git revert.

#### LLM Investigation Trace (v1.3)

The tables below show the full tool-call sequence and token consumption observed
during a Kind run with `claude-sonnet-4-6` on platform version `1.3.0-rc11`.

**Phase 1 — Root Cause Analysis (7 LLM turns, ~40 s)**

| Turn | Tool calls | Prompt (chars) | What happened |
|------|-----------|----------------|---------------|
| 1 | `todo_write`, `kubectl_describe(Pod/web-frontend-…)`, `kubectl_events(Pod/…)` | 4 672 | Planned investigation; identified OOMKilled-like exit code 1, CrashLoopBackOff, 4 restarts |
| 2 | `kubectl_previous_logs(…)`, `kubectl_logs(…)` | 5 026 | Read container logs: `[emerg] invalid directive found in /etc/demo-http-server/config.yaml` |
| 3 | `kubectl_get_by_name(ConfigMap/app-config)` | 18 331 | Fetched ConfigMap — confirmed `invalid_directive: true` in mounted config |
| 4 | `todo_write`, `get_namespaced_resource_context(ConfigMap/app-config)` | 19 853 | Enriched context: detected `gitOpsManaged=true`, `gitOpsTool=argocd`, `environment=staging` |
| 5 | `todo_write` | 20 109 | Updated investigation plan |
| 6 | `todo_write` | 20 369 | Prepared RCA submission |
| 7 | *submit_result (RCA)* | 20 427 | Root cause: ConfigMap/app-config with invalid directive, synced by ArgoCD |

**Phase 2 — Workflow Selection (8 LLM turns, ~46 s)**

| Turn | Tool calls | Prompt (chars) | What happened |
|------|-----------|----------------|---------------|
| 1 | `todo_write` | 7 684 | Planned workflow search |
| 2 | `list_available_actions` | 7 973 | Fetched ActionTypes — identified `GitRevertCommit`, `PatchConfiguration` as candidates |
| 3 | `todo_write`, `list_workflows(GitRevertCommit)`, `list_workflows(PatchConfiguration)` | 9 281 | Queried both action types; found `git-revert-v2` and `hotfix-config-v1` |
| 4 | `todo_write` | 9 730 | Evaluated candidates against GitOps context |
| 5 | `get_workflow(git-revert-v2)` | 12 743 | Reviewed full workflow definition, confirmed label match and `whenToUse` guidance |
| 6 | `todo_write` | 13 083 | Confirmed `git-revert-v2` is the correct choice; `hotfix-config-v1` rejected (GitOps-managed) |
| 7 | `todo_write` | 17 194 | Prepared submission with parameters and rationale |
| 8 | *submit_result_with_workflow* | 17 435 | Selected git-revert-v2 (0.97 confidence) |

**Totals**

| Metric | Value |
|--------|-------|
| **Total tokens** | 114 221 (110 200 prompt + 4 021 completion) |
| **Total tool calls** | 17 |
| **LLM turns** | 15 (7 RCA + 8 Workflow) |
| **Wall-clock time** | ~91 s |
| **Peak prompt size** | 20 427 chars (RCA submit) |

> **Note**: The LLM correctly identified `ConfigMap/app-config` as the RCA target
> (different from the signal Pod), triggering KA's re-enrichment pipeline
> (`signal=Pod/web-frontend → rca_target=ConfigMap/app-config`). It then explicitly
> rejected `PatchConfiguration` because the `whenNotToUse` guidance excludes
> GitOps-managed environments, selecting `GitRevertCommit` as the only durable fix.

#### 8. Verify Remediation

```bash
# After WE Job completes, ArgoCD syncs the reverted ConfigMap
kubectl get pods -n demo-gitops
# All pods should be Running again

# Check git log in Gitea -- should show the revert commit
```

#### 9. Cleanup

```bash
./scenarios/gitops-drift/cleanup.sh
```

#### 10. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Workflow Details

- **Workflow ID**: `git-revert-v2`
- **Action Type**: `GitRevertCommit`
- **Bundle**: `deploy/remediation-workflows/gitops-drift/Dockerfile.exec` (ubi9-minimal + git + kubectl)
- **Script**: `deploy/remediation-workflows/gitops-drift/remediate.sh` (Validate -> Action -> Verify pattern)
