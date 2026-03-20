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
| ArgoCD | Community core-install via `scenarios/gitops/scripts/setup-argocd.sh` | OpenShift GitOps operator (script skips install, provisions credentials only) |
| Memory budget | ~6.1GB total (4.6GB base + 1.5GB GitOps infra) | N/A (cluster-managed) |

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

```bash
# Prometheus alerting rules
kubectl apply -f scenarios/gitops-drift/manifests/prometheus-rule.yaml

# ArgoCD Application (triggers sync of manifests from Gitea)
kubectl apply -f scenarios/gitops-drift/manifests/argocd-application.yaml

# Wait for sync
kubectl wait --for=condition=Available deployment/web-frontend \
  -n demo-gitops --timeout=120s
```

### 3. Verify Healthy State

```bash
kubectl get pods -n demo-gitops
# NAME                            READY   STATUS    RESTARTS   AGE
# web-frontend-xxx-yyy            1/1     Running   0          30s
# web-frontend-xxx-zzz            1/1     Running   0          30s
```

### 4. Inject Failure

```bash
# Port-forward to Gitea
kubectl port-forward -n gitea svc/gitea-http 3000:3000 &

# Clone, break ConfigMap, push
git clone http://kubernaut:kubernaut123@localhost:3000/kubernaut/demo-gitops-repo.git /tmp/gitops-break
cd /tmp/gitops-break

# Edit manifests/configmap.yaml -- add "invalid_directive_that_breaks_nginx on;" to the http block
# This causes nginx to fail config validation on startup, entering CrashLoopBackOff

git add . && git commit -m "chore: update nginx config (broken value)" && git push

# ArgoCD will sync within ~3 minutes (or force sync via ArgoCD UI)
```

### 5. Observe Pipeline

```bash
# Watch pods crash
kubectl get pods -n demo-gitops -w

# Watch Kubernaut CRDs
kubectl get rr,sp,aa,we,ea -n kubernaut-system -w
```

### 6. Verify Remediation

```bash
# After WE Job completes, ArgoCD syncs the reverted ConfigMap
kubectl get pods -n demo-gitops
# All pods should be Running again

# Check git log in Gitea -- should show the revert commit
```

### 7. Cleanup

```bash
./scenarios/gitops-drift/cleanup.sh
```

## Workflow Details

- **Workflow ID**: `git-revert-v2`
- **Action Type**: `GitRevertCommit`
- **Bundle**: `deploy/remediation-workflows/gitops-drift/Dockerfile.exec` (ubi9-minimal + git + kubectl)
- **Script**: `deploy/remediation-workflows/gitops-drift/remediate.sh` (Validate -> Action -> Verify pattern)
