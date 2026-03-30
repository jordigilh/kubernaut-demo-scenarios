# Scenario #135: CrashLoopBackOff with Helm-Managed Workload

## Overview

Demonstrates Kubernaut detecting a CrashLoopBackOff caused by a bad `helm upgrade`
and performing an automatic `helm rollback` to the previous healthy revision.

The key differentiator from scenario #120 (crashloop) is that the workload is deployed
via a Helm chart. HAPI's `get_resource_context` tool detects the
`app.kubernetes.io/managed-by: Helm` label and surfaces `helmManaged: true` as a
cluster-context label. The LLM uses this to select the `HelmRollback` workflow
instead of `RollbackDeployment` (`kubectl rollout undo`).

**Signal**: `KubePodCrashLooping` — restart count increasing rapidly
**Root cause**: Invalid nginx configuration injected via `helm upgrade`
**Remediation**: `helm rollback` restores the previous healthy Helm revision

## Signal Flow

```
kube_pod_container_status_restarts_total increasing → KubePodCrashLooping alert
  → AlertManager webhook → Gateway → RemediationRequest
  → Signal Processing (severity=critical, env=production, P0)
  → AI Analysis (HAPI + Claude Sonnet 4 on Vertex AI)
    → LLM detects helmManaged=true from deployment labels
    → LLM selects HelmRollback workflow (not RollbackDeployment)
  → Remediation Orchestrator → Approval Request (confidence 0.95)
  → WorkflowExecution: helm rollback demo-crashloop-helm 1
  → Effectiveness Monitor: healthScore=1 (all replicas ready)
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services deployed |
| Helm 3 | Installed on the local machine |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics scraping |
| Workflow catalog | `helm-rollback-v1` registered in DataStorage |

## Automated Run

```bash
./scenarios/crashloop-helm/run.sh
```

Options:
- `--interactive` — pause at approval step for manual approval
- `--no-validate` — skip the validation pipeline (deploy + inject only)

## Manual Step-by-Step

### 1. Install the workload via Helm

The scenario includes a local Helm chart in `scenarios/crashloop-helm/chart/` that
deploys an nginx-based worker Deployment with 2 replicas.

```bash
# Kind
helm upgrade --install demo-crashloop-helm scenarios/crashloop-helm/chart \
  -n demo-crashloop-helm --create-namespace --wait --timeout 120s

# OCP (adds SCC-compatible securityContext)
helm upgrade --install demo-crashloop-helm scenarios/crashloop-helm/chart \
  -n demo-crashloop-helm --create-namespace --wait --timeout 120s \
  -f scenarios/crashloop-helm/chart/values-ocp.yaml
```

### 2. Deploy the alerting rule

```bash
kubectl apply -k scenarios/crashloop-helm/manifests/
```

This creates a `PrometheusRule` that fires `KubePodCrashLooping` when
`increase(kube_pod_container_status_restarts_total[10m]) > 3` for 3 minutes.

### 3. Verify healthy state

```bash
kubectl get pods -n demo-crashloop-helm
# NAME                      READY   STATUS    RESTARTS   AGE
# worker-55cb79fcbc-jbbnm   1/1     Running   0          30s
# worker-55cb79fcbc-jhdhs   1/1     Running   0          30s

helm history demo-crashloop-helm -n demo-crashloop-helm
# REVISION  STATUS    DESCRIPTION
# 1         deployed  Install complete
```

### 4. Inject bad configuration via helm upgrade

```bash
bash scenarios/crashloop-helm/inject-bad-config.sh
```

The script creates a temporary values file with an invalid nginx directive
(`invalid_directive_that_breaks_nginx on;`) and runs `helm upgrade`. This creates
Helm revision 2 with the broken config. Pods crash immediately on startup:

```
nginx: [emerg] unknown directive "invalid_directive_that_breaks_nginx"
```

### 5. Observe CrashLoopBackOff

```bash
kubectl get pods -n demo-crashloop-helm
# worker pods cycling: Error -> CrashLoopBackOff -> Error

helm history demo-crashloop-helm -n demo-crashloop-helm
# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete
# 2         deployed    Upgrade complete
```

### 6. Wait for alert and pipeline

The `KubePodCrashLooping` alert fires after the expression is true for 3 minutes
(typically ~4-5 min after injection). Once it fires, the Kubernaut pipeline starts:

```bash
kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

The LLM will:
1. Investigate the crashing pods and read the nginx error logs
2. Identify the root cause as an invalid ConfigMap introduced by `helm upgrade`
3. Detect `helmManaged=true` from the `app.kubernetes.io/managed-by: Helm` label
4. Select `HelmRollback` over `RollbackDeployment` because the workload is Helm-managed
5. Request human approval (production environment, confidence 0.95)

### 7. Inspect AI Analysis

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

### 8. Verify remediation

After approval and workflow execution:

```bash
kubectl get pods -n demo-crashloop-helm
# All pods Running/Ready with no recent restarts

helm history demo-crashloop-helm -n demo-crashloop-helm
# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete
# 2         superseded  Upgrade complete
# 3         deployed    Rollback to 1
```

## Cleanup

```bash
./scenarios/crashloop-helm/cleanup.sh
```

## BDD Specification

```gherkin
Feature: Helm-managed CrashLoopBackOff remediation

  Scenario: Bad config via helm upgrade triggers CrashLoopBackOff
    Given a Helm-managed deployment in namespace "demo-crashloop-helm"
      And the deployment has label "app.kubernetes.io/managed-by: Helm"
      And the workload is healthy with 2 replicas (Helm revision 1)

    When an invalid nginx config is applied via "helm upgrade" (revision 2)
      And the worker pods enter CrashLoopBackOff
      And the KubePodCrashLooping alert fires (>3 restarts in 10m, sustained 3m)

    Then Gateway receives the alert via AlertManager webhook
      And Signal Processing enriches with severity=critical, environment=production, P0
      And HAPI detects helmManaged=true from deployment labels
      And the LLM diagnoses bad ConfigMap from nginx error logs
      And the LLM selects HelmRollback workflow (not RollbackDeployment)
      And Remediation Orchestrator requests human approval (confidence 0.95)
      And WorkflowExecution runs "helm rollback" to revision 1
      And Effectiveness Monitor confirms healthScore=1 (all replicas ready)
      And Helm history shows revision 3 with "Rollback to 1"
```

## Acceptance Criteria

- [ ] Helm chart deploys worker with `app.kubernetes.io/managed-by: Helm` label
- [ ] `helm upgrade` with bad nginx config causes CrashLoopBackOff
- [ ] PrometheusRule fires KubePodCrashLooping (>3 restarts in 10m, `for: 3m`)
- [ ] HAPI detects `helmManaged=true` and surfaces it as cluster context
- [ ] LLM selects `HelmRollback` action type (not `RollbackDeployment`)
- [ ] WE Job runs `helm rollback` to the previous healthy revision
- [ ] Helm history shows revision 3 as "Rollback to 1"
- [ ] All worker replicas are Running/Ready after rollback
- [ ] EA completes with healthScore=1
- [ ] Works on both Kind and OCP (with `values-ocp.yaml` overlay)
