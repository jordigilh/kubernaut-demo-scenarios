# Scenario #134: cert-manager Certificate Failure with GitOps

## Overview

Same fault as #133 (cert-manager Certificate stuck NotReady) but cert-manager resources (Certificate, ClusterIssuer) are managed by ArgoCD via Gitea. Remediation uses **git revert** instead of direct kubectl changes.

**Key differentiator**: The LLM detects `gitOpsManaged=true` and `gitOpsTool=argocd` from the environment. It may select the GitOps-aware workflow (`fix-certificate-gitops-v1`) that reverts the bad commit, or the direct-fix workflow (`fix-certificate-v1`) that recreates the missing CA Secret. Both are valid remediations that restore certificate issuance. See [Observed Alternative](#observed-alternative-fixcertificate-direct-remediation) for details.

| | |
|---|---|
| **Signal** | `CertManagerCertNotReady` — from `certmanager_certificate_ready_status` |
| **Root cause** | Bad Git commit changed ClusterIssuer to reference non-existent CA Secret |
| **Remediation** | `fix-certificate-gitops-v1` workflow performs git revert |

## Signal Flow

```
certmanager_certificate_ready_status == 0 for 2m → CertManagerCertNotReady alert
  → Gateway → SP → AA (HAPI + real LLM)
  → HAPI LabelDetector detects gitOpsManaged=true, gitOpsTool=argocd
  → LLM diagnoses broken ClusterIssuer (bad commit) as root cause
  → LLM selects fix-certificate-gitops-v1 (git-based fix) over fix-certificate-v1 (kubectl)
  → RO → WE Job (git revert HEAD, push to Gitea)
  → ArgoCD re-syncs restored ClusterIssuer
  → EM verifies Certificate is Ready
```

## Prerequisites

| Component | Kind | OCP |
|-----------|------|-----|
| Cluster | `scenarios/kind-config-singlenode.yaml` | OpenShift 4.x cluster |
| LLM backend | Real LLM (not mock) via HAPI | Same |
| Prometheus | With cert-manager metrics | OCP monitoring stack |
| cert-manager | Installed (run.sh installs if missing) | Same |
| Gitea | Via `scenarios/gitops/scripts/setup-gitea.sh` | Same (adds OCP-compatible securityContext) |
| ArgoCD | Community core-install via `scenarios/gitops/scripts/setup-argocd.sh` | OpenShift GitOps operator (script provisions credentials only) |
| Workflow catalog | `fix-certificate-gitops-v1` registered in DataStorage | Same |
| Memory budget | ~6.1GB total (4.6GB base + 1.5GB GitOps infra) | N/A (cluster-managed) |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `fix-certificate-gitops-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `fix-certificate-gitops-v1-runner` |
| ClusterRoleBinding | `fix-certificate-gitops-v1-runner` |

**Permissions**:

| API group | Resources | Verbs |
|-----------|-----------|-------|
| argoproj.io | applications | get, list |
| cert-manager.io | certificates | get, list |

## BDD Specification

```gherkin
Feature: cert-manager Certificate failure remediation via git revert (GitOps)

  Scenario: Broken ClusterIssuer causes Certificate NotReady in GitOps environment
    Given ArgoCD manages Certificate "demo-app-cert" and ClusterIssuer "demo-selfsigned-ca-gitops"
      And the Gitea repository contains healthy cert-manager manifests synced by ArgoCD
      And the Certificate is Ready and the demo-app Deployment is Running

    When a bad commit is pushed to Gitea changing ClusterIssuer to reference "nonexistent-ca-secret"
      And ArgoCD syncs the broken ClusterIssuer to the cluster
      And the TLS secret is deleted to trigger re-issuance
      And cert-manager fails to issue because the ClusterIssuer cannot sign

    Then Prometheus fires "CertManagerCertNotReady" alert for namespace "demo-cert-gitops"
      And Gateway creates a RemediationRequest
      And Signal Processing enriches with namespace labels (environment=production, criticality=high)
      And HAPI LabelDetector detects "gitOpsManaged=true" and "gitOpsTool=argocd"
      And the LLM traces the Certificate NotReady to broken ClusterIssuer (bad Git commit)
      And the LLM selects "fix-certificate-gitops-v1" workflow (not "fix-certificate-v1")
      And Remediation Orchestrator creates WorkflowExecution
      And the WE Job clones the Gitea repo and runs "git revert HEAD"
      And ArgoCD syncs the reverted ClusterIssuer back to the cluster
      And Effectiveness Monitor verifies Certificate is Ready
```

## Acceptance Criteria

- [ ] Gitea + ArgoCD deployed and managing `demo-cert-gitops` namespace
- [ ] Certificate and ClusterIssuer are GitOps-managed (synced from Gitea)
- [ ] Bad ClusterIssuer commit causes Certificate to become NotReady
- [ ] SP enriches signal with business classification from namespace labels
- [ ] HAPI detects `gitOpsManaged=true` and `gitOpsTool=argocd` (DD-HAPI-018)
- [ ] LLM identifies broken ClusterIssuer (bad commit) as root cause
- [ ] LLM selects `fix-certificate-gitops-v1` (git revert) over `fix-certificate-v1` (kubectl)
- [ ] WE Job performs `git revert` in Gitea repository
- [ ] ArgoCD auto-syncs the reverted ClusterIssuer
- [ ] EM verifies Certificate is Ready
- [ ] Full pipeline: Gateway -> RO -> SP -> AA -> WE -> EM

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
./scenarios/cert-failure-gitops/run.sh
```

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/cert-failure-gitops/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Install Prerequisites

```bash
# cert-manager (run.sh installs via Helm automatically; for manual setup:)
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 3m

# GitOps infrastructure
./scenarios/gitops/scripts/setup-gitea.sh
./scenarios/gitops/scripts/setup-argocd.sh
```

#### 2. Run the Scenario

```bash
./scenarios/cert-failure-gitops/run.sh
```

The script will: create CA, push manifests to Gitea, deploy ArgoCD Application, establish baseline, inject failure via bad git push, and wait for the pipeline.

#### 3. Observe Pipeline

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  amtool alert query alertname=CertManagerCertNotReady --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=CertManagerCertNotReady --alertmanager.url=http://localhost:9093
```

</details>

```bash
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

#### 4. Inspect AI Analysis

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

#### 5. Verify Remediation

```bash
kubectl get certificate -n demo-cert-gitops
# demo-app-cert should show Ready=True after workflow completes
```

#### 6. Cleanup

```bash
./scenarios/cert-failure-gitops/cleanup.sh
```

#### 7. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Workflow Details

- **Workflow ID**: `fix-certificate-gitops-v1`
- **Action Type**: `GitRevertCommit`
- **Bundle**: `deploy/remediation-workflows/cert-failure-gitops/Dockerfile.exec` (ubi9-minimal + git + kubectl)
- **Script**: `deploy/remediation-workflows/cert-failure-gitops/remediate.sh` (Validate -> Action pattern; RO/EM handle verification)

## Observed Alternative: FixCertificate (Direct Remediation)

During live validation, the LLM chose `FixCertificate` instead of `GitRevertCommit`.
This section documents the observed behavior and its implications.

### What Happened

The LLM correctly identified the root cause (missing CA Secret `nonexistent-ca-secret`
backing the ClusterIssuer) but selected the `fix-certificate-v1` workflow, which creates
the Secret directly in the cluster rather than reverting the bad Git commit.

**LLM rationale**:

> "Despite GitOps management, this is an infrastructure-level certificate issue requiring
> direct remediation."

The remediation completed in ~10 seconds (vs ~3 minutes for the git-based path), the
certificate was restored to Ready, and the Effectiveness Assessment scored 1/1 on both
alert and health checks.

### Why Both Approaches Are Valid

Kubernaut's mission is to reduce MTTR -- restore service health and silence the alert.
Both paths achieve this goal:

| Aspect | GitRevertCommit | FixCertificate |
|--------|:-:|:-:|
| Alert remediated | Yes | Yes |
| Certificate restored | Yes | Yes |
| MTTR | ~3 min | ~10 sec |
| Git state | Clean | Dirty (broken commit remains) |
| Long-term stability | Stable | Requires follow-up git fix |

The permanent fix (cleaning up the Git repository) remains the responsibility of the
engineering team during post-incident review.

### Confidence and Approval

The LLM set confidence to **0.85** and triggered a human approval request. This shows
the LLM was aware that choosing direct remediation in a GitOps environment is a
consequential decision that warrants human confirmation -- a sign of genuine situational
awareness.

### Recurrence Behavior

When the problem was re-triggered (Secret deleted again), HAPI's `get_resource_context`
tool queried DataStorage and returned the remediation history for the resource
(`history_count=5`), including the previous successful `FixCertificate` outcome with
verified effectiveness scores. The LLM chose the same approach (`FixCertificate`,
confidence 0.85, same rationale) -- reinforced by historical evidence that the
previous remediation succeeded.

If the same workflow keeps completing but the problem recurs, Kubernaut's remediation
history prompt automatically warns the LLM to escalate to human review rather than
repeating an ineffective loop.

### AIOps Insight

A rule-based system would enforce a single path: `if GitOps then revert commit`. The LLM
reasons about the actual problem and may choose differently depending on what it judges
most appropriate. This flexibility is a strength of AIOps -- real-world problems rarely
have a single correct solution.

For a deeper analysis, see the
[Multi-Path Remediation](https://jordigilh.github.io/kubernaut-docs/use-cases/multi-path-remediation/)
use case in the Kubernaut documentation.
