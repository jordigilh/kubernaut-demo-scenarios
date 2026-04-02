# Scenario #120: CrashLoopBackOff Remediation

## Demo

![Kubernaut detecting and remediating a CrashLoopBackOff](crashloop-lite.gif)

## Overview

Demonstrates Kubernaut detecting a CrashLoopBackOff caused by a bad configuration
change and performing an automatic rollback to the previous working revision.

**Signal**: `KubePodCrashLooping` -- restart count increasing rapidly
**Root cause**: Invalid nginx configuration deployed via ConfigMap swap
**Remediation**: `kubectl rollout undo` restores the previous healthy revision

## Signal Flow

```
kube_pod_container_status_restarts_total increasing → KubePodCrashLooping alert
  → Gateway → SP → AA (HAPI + real LLM)
  → LLM diagnoses bad config causing CrashLoopBackOff
  → Selects GracefulRestart (rollback) workflow
  → RO → WE (kubectl rollout undo)
  → EM verifies pods running, restarts stabilized
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Kind cluster | `overlays/kind/kind-cluster-config.yaml` |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics |
| Workflow catalog | `crashloop-rollback-v1` registered in DataStorage |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `crashloop-rollback-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `crashloop-rollback-v1-runner` |
| ClusterRoleBinding | `crashloop-rollback-v1-runner` |

**Permissions**: `apps` deployments (get, list, patch, update), `apps` replicasets (get, list), core pods (get, list)

## Automated Run

```bash
./scenarios/crashloop/run.sh
```

## Manual Step-by-Step

### 1. Deploy the healthy workload

```bash
kubectl apply -f scenarios/crashloop/manifests/namespace.yaml
kubectl apply -f scenarios/crashloop/manifests/configmap.yaml
kubectl apply -f scenarios/crashloop/manifests/deployment.yaml
kubectl apply -f scenarios/crashloop/manifests/prometheus-rule.yaml
kubectl wait --for=condition=Available deployment/worker -n demo-crashloop --timeout=120s
```

### 2. Verify healthy state

```bash
kubectl get pods -n demo-crashloop
# All pods should be Running with 0 restarts
```

### 3. Inject bad configuration

```bash
bash scenarios/crashloop/inject-bad-config.sh
```

The script creates a `worker-config-bad` ConfigMap with an invalid nginx directive and
patches the deployment to reference it. Pods will crash on startup.

### 4. Observe CrashLoopBackOff

```bash
kubectl get pods -n demo-crashloop -w
# Pods cycle: Error -> CrashLoopBackOff -> Error -> ...
```

### 5. Wait for alert and pipeline

```bash
# Alert fires after >3 restarts in 10 min (~2-3 min)
# Check: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
#        then open http://localhost:9090/alerts

# Query Alertmanager for active alerts
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  amtool alert query alertname=KubePodCrashLooping --alertmanager.url=http://localhost:9093

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

# Approval context and investigation narrative
kubectl get $AIA -n kubernaut-system -o jsonpath='
Approval:    {.status.approvalRequired}
Reason:      {.status.approvalContext.reason}
Confidence:  {.status.approvalContext.confidenceLevel}
'; echo
kubectl get $AIA -n kubernaut-system -o jsonpath='{.status.approvalContext.investigationSummary}'; echo
```

### 7. Verify remediation

```bash
kubectl get pods -n demo-crashloop
# All pods Running/Ready with no recent restarts
kubectl rollout history deployment/worker -n demo-crashloop
```

## Cleanup

```bash
./scenarios/crashloop/cleanup.sh
```

## BDD Specification

```gherkin
Given a Kind cluster with Kubernaut services and a real LLM backend
  And Prometheus is scraping kube-state-metrics
  And the "crashloop-rollback-v1" workflow is registered in the DataStorage catalog
  And the "worker" deployment is running healthily in namespace "demo-crashloop"

When a bad ConfigMap is deployed that causes nginx to fail on startup
  And the deployment is patched to reference the bad ConfigMap
  And pods enter CrashLoopBackOff with rapidly increasing restart counts
  And the KubePodCrashLooping alert fires (>3 restarts in 10 min)

Then Kubernaut Gateway receives the alert via Alertmanager webhook
  And Signal Processing enriches the signal with business labels
  And AI Analysis (HAPI + LLM) diagnoses CrashLoopBackOff from bad configuration
  And the LLM selects the "GracefulRestart" workflow (crashloop-rollback-v1)
  And Remediation Orchestrator creates a WorkflowExecution
  And Workflow Execution rolls back the deployment to the previous revision
  And the pods start successfully with the restored healthy configuration
  And Effectiveness Monitor confirms the deployment is healthy and restarts stabilized
```

## Acceptance Criteria

- [ ] Worker deployment starts healthy and serves traffic
- [ ] Bad config injection causes immediate CrashLoopBackOff
- [ ] Alert fires within 2-3 minutes of first crash
- [ ] LLM correctly diagnoses bad config as root cause
- [ ] Rollback restores the original healthy ConfigMap reference
- [ ] All pods become Running/Ready after rollback
- [ ] Restart count stabilizes (no further restarts)
- [ ] EM confirms successful remediation
