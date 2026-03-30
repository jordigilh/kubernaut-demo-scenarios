# Scenario #123: HPA Maxed Out

## Overview

Demonstrates Kubernaut leveraging **detected labels** (`hpaEnabled: true`) to
contextually remediate an HPA that has hit its `maxReplicas` ceiling during a
traffic spike. The LLM knows an HPA exists and patches it to temporarily raise
the ceiling, allowing the autoscaler to absorb the load.

**Detected label**: `hpaEnabled: true` — LLM context includes HPA configuration
**Signal**: `KubeHpaMaxedOut` — HPA at maxReplicas for >3 min
**Root cause**: CPU utilization 4x above target with maxReplicas too low
**Remediation**: Patch HPA to increase `maxReplicas` from 3 to 5

## Signal Flow

```
CPU stress → HPA scales to maxReplicas (3) → can't scale further
  → kube_horizontalpodautoscaler_status_current_replicas == spec_max_replicas
  → KubeHpaMaxedOut alert (severity: warning, for: 3m)
  → AlertManager webhook → Gateway → RemediationRequest
  → Signal Processing
  → AI Analysis (HAPI + Claude Sonnet 4 on Vertex AI)
    → Detected labels: hpaEnabled=true
    → Root cause: maxReplicas ceiling too low, CPU at 200% of target
    → Contributing factors: HPA limit too low, utilization 4x target, no headroom
    → Selected: PatchHPA (confidence 0.95)
    → Parameters: NEW_MAX_REPLICAS=5, TARGET_RESOURCE_NAME=api-frontend, TARGET_RESOURCE_KIND=HorizontalPodAutoscaler
    → Approval: not required (auto-approved by policy)
  → WorkflowExecution: kubectl patch hpa api-frontend --maxReplicas=5
  → HPA scales to 5 replicas → CPU drops to normal
  → Effectiveness Monitor: healthScore=1
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services deployed |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics scraping |
| metrics-server | Required for HPA CPU metrics (built-in on OCP) |
| Workflow catalog | `patch-hpa-v1` registered in DataStorage |
| HAPI Prometheus | Auto-enabled by `run.sh`, reverted by `cleanup.sh` (#108) |

## Automated Run

```bash
./scenarios/hpa-maxed/run.sh
```

Options:
- `--interactive` — pause at approval step for manual approval
- `--no-validate` — skip the validation pipeline (deploy + inject only)

## Manual Step-by-Step

### 1. Deploy the workload with HPA

```bash
# Kind
kubectl apply -k scenarios/hpa-maxed/manifests/

# OCP (uses nginx-unprivileged on port 8080)
kubectl apply -k scenarios/hpa-maxed/overlays/ocp/

kubectl wait --for=condition=Available deployment/api-frontend -n demo-hpa --timeout=120s
```

This creates a 2-replica `api-frontend` Deployment with:
- CPU request: 50m / limit: 100m
- HPA targeting 50% CPU utilization, minReplicas=2, maxReplicas=3

### 2. Verify HPA

```bash
kubectl get hpa -n demo-hpa
# NAME           REFERENCE                 TARGETS          MINPODS   MAXPODS   REPLICAS
# api-frontend   Deployment/api-frontend   cpu: <low>/50%   2         3         2
```

### 3. Inject CPU load

```bash
bash scenarios/hpa-maxed/inject-load.sh
```

The script runs `yes > /dev/null` inside each pod (3 processes per pod) to saturate
CPU. When HPA scales to 3 replicas, the script re-stresses the new pod.

### 4. Watch HPA scale to ceiling

```bash
kubectl get hpa -n demo-hpa -w
# REPLICAS climbs to 3 (maxReplicas) and stays there
# CPU utilization remains high (200%+ of target)
```

### 5. Wait for alert

The `KubeHpaMaxedOut` alert fires when `currentReplicas == maxReplicas` for 3 minutes.
Typical time from injection: ~5 min on Kind, ~3-5 min on OCP.

### 6. Monitor the pipeline

```bash
kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

The LLM will:
1. Detect `hpaEnabled: true` from the deployment's context labels
2. Read the HPA configuration and current CPU metrics
3. Identify that maxReplicas (3) is too low for current load (CPU at 200% of target)
4. Select `PatchHPA` workflow with `NEW_MAX_REPLICAS=5`
5. Auto-approve (warning severity, policy does not require manual review)

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
```

### 8. Verify remediation

After the workflow execution completes:

```bash
kubectl get hpa -n demo-hpa
# NAME           REFERENCE                 TARGETS       MINPODS   MAXPODS   REPLICAS
# api-frontend   Deployment/api-frontend   cpu: 2%/50%   2         5         5

kubectl get pods -n demo-hpa
# 5 pods Running (scaled beyond old ceiling of 3)
```

The `validate.sh` script kills the CPU stress processes during the Verifying phase,
allowing HPA to naturally scale back down and the alert to resolve.

## Cleanup

```bash
./scenarios/hpa-maxed/cleanup.sh
```

## Pipeline Timeline (OCP observed)

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy + baseline | T+0:00 | — |
| Inject CPU stress | T+0:15 | — |
| HPA scales to 3 (maxReplicas) | T+0:45 | ~30 s after stress |
| KubeHpaMaxedOut alert fires | T+3:13 | `for: 3m` after ceiling hit |
| RR created | T+3:20 | 7 s after alert |
| AA completes | T+4:59 | 106 s investigation (7 poll cycles) |
| Auto-approved | T+4:59 | Immediate |
| WFE completes (maxReplicas 3→5) | T+5:44 | 45 s job execution |
| Stress killed (root cause fix) | T+5:44 | On Verifying phase hook |
| EA completes (healthScore=1) | T+6:43 | 59 s health check |
| **Total** | **~7 min** | |

## BDD Specification

```gherkin
Feature: HPA ceiling remediation via detected labels

  Scenario: HPA at maxReplicas triggers PatchHPA workflow
    Given a deployment "api-frontend" in namespace "demo-hpa"
      And an HPA with minReplicas=2, maxReplicas=3, targetCPU=50%
      And the "patch-hpa-v1" workflow is registered with detectedLabels: hpaEnabled

    When CPU load drives the HPA to its maxReplicas ceiling
      And the HPA cannot scale further despite CPU at 200% of target
      And the KubeHpaMaxedOut alert fires (for: 3m)

    Then Gateway receives the alert via AlertManager webhook
      And Signal Processing enriches the signal
      And HAPI detects hpaEnabled=true from deployment context
      And the LLM reads HPA configuration and CPU metrics
      And the LLM selects PatchHPA (confidence 0.95)
      And parameters include NEW_MAX_REPLICAS=5
      And auto-approval is granted (warning severity)
      And WorkflowExecution patches the HPA maxReplicas to 5
      And the HPA scales beyond the original ceiling
      And Effectiveness Monitor confirms healthScore=1
```

## Acceptance Criteria

- [ ] HPA reaches maxReplicas (3) under CPU load
- [ ] KubeHpaMaxedOut alert fires after 3 min at ceiling
- [ ] `hpaEnabled: true` detected label is surfaced in AA context
- [ ] LLM selects PatchHPA workflow (not GracefulRestart or other)
- [ ] Confidence >= 0.95
- [ ] Auto-approved (no RAR created)
- [ ] `maxReplicas` raised from 3 to 5
- [ ] HPA scales beyond original ceiling to meet demand
- [ ] EA confirms healthScore=1
- [ ] CPU utilization returns to normal after stress removal
- [ ] Works on both Kind and OCP (with unprivileged nginx overlay)
