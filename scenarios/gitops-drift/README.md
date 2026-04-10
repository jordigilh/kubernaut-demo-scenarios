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
| Kubernaut services | All controllers deployed with real LLM backend | Same |
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

**Permissions**: `argoproj.io` applications (get, list), core pods (get, list)

## BDD Specification

```gherkin
Feature: GitOps drift remediation via git revert

  Scenario: Broken ConfigMap causes CrashLoopBackOff in GitOps environment
    Given ArgoCD manages nginx Deployment "web-frontend" in namespace "demo-gitops"
      And the Deployment mounts ConfigMap "nginx-config" as /etc/nginx/nginx.conf via volumeMounts
      And the Gitea repository contains healthy manifests synced by ArgoCD
      And all pods are Running and Ready

    When a bad commit is pushed to Gitea changing ConfigMap "nginx-config" to an invalid value
      And ArgoCD syncs the broken ConfigMap to the cluster
      And nginx pods restart and enter CrashLoopBackOff

    Then Prometheus fires "KubePodCrashLooping" alert for namespace "demo-gitops"
      And Gateway creates a RemediationRequest
      And Signal Processing enriches with namespace labels (environment=staging, criticality=high)
      And HAPI LabelDetector detects "gitOpsManaged=true" from ArgoCD annotations
      And the LLM traces the crash to ConfigMap "nginx-config" (RCA resource != signal resource)
      And the LLM selects "GitRevertCommit" workflow (not "RollbackDeployment")
      And Remediation Orchestrator creates WorkflowExecution
      And the WE Job clones the Gitea repo and runs "git revert HEAD"
      And ArgoCD syncs the reverted ConfigMap back to the cluster
      And Effectiveness Monitor verifies pods are Running and Ready
```

## Acceptance Criteria

- [ ] Gitea + ArgoCD deployed and managing `demo-gitops` namespace
- [ ] Bad ConfigMap commit causes nginx CrashLoopBackOff
- [ ] SP enriches signal with business classification from namespace labels
- [ ] HAPI detects `gitOpsManaged=true` from ArgoCD annotations (DD-HAPI-018)
- [ ] LLM identifies ConfigMap as root cause (signal != RCA)
- [ ] LLM selects `GitRevertCommit` workflow over `RollbackDeployment`
- [ ] WE Job performs `git revert` in Gitea repository
- [ ] ArgoCD auto-syncs the reverted state
- [ ] EM verifies Deployment health restored
- [ ] Full pipeline: Gateway -> RO -> SP -> AA -> WE -> EM

## Automated Run

```bash
./scenarios/gitops-drift/run.sh
```

## Manual Step-by-Step

### 1. Install GitOps Infrastructure

```bash
# Install Gitea (creates repo with healthy manifests)
./scenarios/gitops/scripts/setup-gitea.sh

# Install ArgoCD (registers Gitea repo credentials)
./scenarios/gitops/scripts/setup-argocd.sh
```

### 2. Deploy Scenario Resources

Apply the full kustomization (namespace, PrometheusRule, ArgoCD Application, etc.)
in one step. On OCP, use the overlay so the ArgoCD Application targets
`openshift-gitops` and the namespace gets the cluster-monitoring label:

```bash
# Kind
kubectl apply -k scenarios/gitops-drift/manifests

# OCP
kubectl apply -k scenarios/gitops-drift/overlays/ocp

# Wait for ArgoCD to sync and the deployment to become available
kubectl wait --for=condition=Available deployment/web-frontend \
  -n demo-gitops --timeout=120s
```

### 3. Verify Healthy State

```bash
kubectl get pods -n demo-gitops
# NAME                            READY   STATUS    RESTARTS   AGE
# web-frontend-xxx-yyy            1/1     Running   0          30s
```

### 4. Inject Failure

> **Important**: The injected `configmap.yaml` must remain valid YAML. If ArgoCD
> cannot parse the manifest (e.g. tab characters, broken indentation), it will
> reject the sync entirely and the deployment will never update — no crash, no
> alert, no pipeline.
>
> **Note**: The commands below use `nginx:1.27-alpine` (Kind). On OCP, replace
> with `nginxinc/nginx-unprivileged:1.27-alpine` to comply with restricted SCCs.

```bash
# Port-forward to Gitea
kubectl port-forward -n gitea svc/gitea-http 3031:3000 &

# Clone the repo
git clone http://kubernaut:kubernaut123@localhost:3031/kubernaut/demo-gitops-repo.git /tmp/gitops-break
cd /tmp/gitops-break

# Overwrite configmap.yaml with an invalid nginx directive (valid YAML, broken nginx config)
cat > manifests/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: demo-gitops
  labels:
    app: web-frontend
data:
  nginx.conf: |
    worker_processes auto;
    error_log /var/log/nginx/error.log warn;
    pid /tmp/nginx.pid;

    events {
        worker_connections 1024;
    }

    http {
        # INVALID: causes nginx to fail on startup
        invalid_directive_that_breaks_nginx on;

        server {
            listen 8080;
            server_name _;

            location / {
                return 200 'healthy\n';
                add_header Content-Type text/plain;
            }

            location /healthz {
                return 200 'ok\n';
                add_header Content-Type text/plain;
            }
        }
    }
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
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
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
          name: nginx-config
EOF

git add .
git commit -m "chore: update nginx config (broken value)"
git push origin main

# The Gitea webhook notifies ArgoCD immediately; sync happens within seconds
```

### 5. Observe Pipeline

```bash
# Watch pods crash
kubectl get pods -n demo-gitops -w

# Query Alertmanager for active alerts
# Kind:
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  amtool alert query alertname=KubePodCrashLooping --alertmanager.url=http://localhost:9093
# OCP:
# kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
#   amtool alert query alertname=KubePodCrashLooping --alertmanager.url=http://localhost:9093

# Watch Kubernaut CRDs
kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system -w
```

### 6. Inspect AI Analysis

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

### 7. Verify Remediation

```bash
# After WE Job completes, ArgoCD syncs the reverted ConfigMap
kubectl get pods -n demo-gitops
# All pods should be Running again

# Check git log in Gitea -- should show the revert commit
```

### 8. Cleanup

```bash
./scenarios/gitops-drift/cleanup.sh
```

## Workflow Details

- **Workflow ID**: `git-revert-v1`
- **Action Type**: `GitRevertCommit`
- **Bundle**: `deploy/remediation-workflows/gitops-drift/Dockerfile.exec` (ubi9-minimal + git + kubectl)
- **Script**: `deploy/remediation-workflows/gitops-drift/remediate.sh` (Validate -> Action -> Verify pattern)
