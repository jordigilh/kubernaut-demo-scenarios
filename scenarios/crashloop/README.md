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
| Cluster | Kind or OCP 4.21+ with Kubernaut services deployed |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics |
| Workflow catalog | `crashloop-rollback-v1` registered in DataStorage |

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
kubectl get rr,sp,aa,we,ea -n demo-crashloop -w
```

### 6. Verify remediation

```bash
kubectl get pods -n demo-crashloop
# All pods Running/Ready with no recent restarts
kubectl rollout history deployment/worker -n demo-crashloop
```

## Cleanup

```bash
./scenarios/crashloop/cleanup.sh
```

## LLM Analysis (OCP observed — rc4)

| Field | Value |
|-------|-------|
| Root Cause | `Pod crashes due to invalid nginx configuration directive 'invalid_directive_that_breaks_nginx' in ConfigMap worker-config-bad, causing nginx startup failure` |
| Severity | `high` |
| Confidence | 0.95 |
| Selected Workflow | `RollbackDeployment` (`crashloop-rollback-v1`) |
| Approval | Required — production environment |
| Rationale | The crash is caused by a bad configuration change in the current deployment revision. Rolling back to the previous healthy revision will restore the working nginx configuration and resolve the CrashLoopBackOff. This workflow is appropriate for the medium risk tolerance and P0 priority. |

The LLM correctly identifies `worker-config-bad` as the root cause with 95% confidence
and selects `RollbackDeployment` to perform `kubectl rollout undo`.

## Pipeline Timeline (OCP observed — rc4)

| Event | UTC | Delta |
|-------|-----|-------|
| Inject bad config | 18:41:05 | — |
| `KubePodCrashLooping` fires | 18:46:05 | +5m 00s |
| RR created → Analyzing | 18:46:06 | +0m 01s |
| AA complete → AwaitingApproval | 18:47:39 | +1m 33s |
| RAR auto-approved | 18:47:43 | +0m 04s |
| WFE starts (Executing) | 18:47:53 | +0m 10s |
| WFE complete → Verifying | 18:48:04 | +0m 11s |
| EA complete → Completed | 18:55:07 | +7m 03s |
| **Total pipeline** | | **9m 02s** |

## Effectiveness Assessment (OCP observed — rc4)

| Field | Value |
|-------|-------|
| Phase | Completed |
| Reason | partial |
| Health Score | 1 |
| Alert Score | pending |
| Metrics Score | pending |

## BDD Specification

```gherkin
Given a Kind or OCP cluster with Kubernaut services and a real LLM backend
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

- [x] Worker deployment starts healthy and serves traffic
- [x] Bad config injection causes immediate CrashLoopBackOff
- [x] Alert fires within 2-3 minutes of first crash
- [x] LLM correctly diagnoses bad config as root cause
- [x] Rollback restores the original healthy ConfigMap reference
- [x] All pods become Running/Ready after rollback
- [x] Restart count stabilizes (no further restarts)
- [x] EM confirms successful remediation
