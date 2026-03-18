# Scenario #130: Stuck Rollout

## Overview

A deployment update gets stuck because the new image tag doesn't exist. After exceeding
`progressDeadlineSeconds` (120 s), Kubernetes marks the rollout as not progressing. Kubernaut
detects the `KubeDeploymentRolloutStuck` alert, diagnoses the bad image reference, and
rolls back to the previous working revision.

An interesting aspect of this scenario is the LLM's workflow selection: it considers
both `RollbackDeployment` (confidence 0.95) and an alternative `CrashLoopRollback`
workflow (confidence 0.75), correctly preferring the former because the pods are in
`ImagePullBackOff`, not `CrashLoopBackOff`.

**Signal**: `KubeDeploymentRolloutStuck` — Progressing condition is False for >1 min
**Root cause**: Non-existent image tag `nginx:99.99.99-doesnotexist`
**Remediation**: `kubectl rollout undo` restores previous working revision

## Signal Flow

```
kube_deployment_status_condition{condition="Progressing",status="false"} == 1
  → KubeDeploymentRolloutStuck alert (severity: critical, for: 1m)
  → AlertManager webhook → Gateway → RemediationRequest
  → Signal Processing
  → AI Analysis (HAPI + Claude Sonnet 4 on Vertex AI)
    → Root cause: invalid image tag causing ImagePullBackOff
    → Contributing factors: invalid tag, config error in spec, rolling update blocking
    → Selected: RollbackDeployment (confidence 0.95)
    → Alternative considered: CrashLoopRollback (0.75, rejected — wrong failure mode)
    → Approval: required (production environment, critical severity)
  → WorkflowExecution: kubectl rollout undo deployment/checkout-api
  → Effectiveness Monitor: healthScore=1 (all 3 replicas Running)
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services deployed |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics scraping |
| Workflow catalog | `rollback-deployment-v1` registered in DataStorage |

## Automated Run

```bash
./scenarios/stuck-rollout/run.sh
```

Options:
- `--interactive` — pause at approval step for manual approval
- `--no-validate` — skip the validation pipeline (deploy + inject only)

## Manual Step-by-Step

### 1. Deploy the workload

```bash
kubectl apply -k scenarios/stuck-rollout/manifests/
kubectl wait --for=condition=Available deployment/checkout-api \
  -n demo-rollout --timeout=120s
```

This creates a 3-replica `checkout-api` Deployment running `nginx:1.27-alpine`,
a Service, and a PrometheusRule.

### 2. Verify healthy state

```bash
kubectl get pods -n demo-rollout
# NAME                            READY   STATUS    RESTARTS   AGE
# checkout-api-84b5c88cd4-98m5t   1/1     Running   0          6s
# checkout-api-84b5c88cd4-c8crh   1/1     Running   0          6s
# checkout-api-84b5c88cd4-qxjvx   1/1     Running   0          6s
```

### 3. Establish baseline (15 s)

Wait briefly for Prometheus to capture the healthy state before fault injection.

### 4. Inject bad image

```bash
bash scenarios/stuck-rollout/inject-bad-image.sh
```

The script runs `kubectl set image deployment/checkout-api api=nginx:99.99.99-doesnotexist`.
New pods enter `ImagePullBackOff` immediately. The rollout strategy (`RollingUpdate`)
keeps the old pods running while the new ReplicaSet fails to become ready.

```bash
kubectl get pods -n demo-rollout
# checkout-api-84b5c88cd4-98m5t   1/1     Running             0          2m
# checkout-api-84b5c88cd4-c8crh   1/1     Running             0          2m
# checkout-api-84b5c88cd4-qxjvx   1/1     Running             0          2m
# checkout-api-xxxxxxxxxx-yyyyy   0/1     ImagePullBackOff    0          30s
```

### 5. Wait for alert

The `KubeDeploymentRolloutStuck` alert requires two conditions:
1. `progressDeadlineSeconds` exceeded (120 s) — Kubernetes sets `Progressing=False`
2. Alert `for: 1m` — Prometheus waits 1 more minute to confirm

Total time from injection to alert: **~3 min** (Kind) / **~6 min** (OCP, longer scrape intervals).

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# open http://localhost:9090/alerts
```

### 6. Monitor the pipeline

```bash
kubectl get rr,sp,aa,we,ea -n kubernaut-system
```

The LLM will:
1. Investigate the stuck rollout and inspect pod events
2. Identify `nginx:99.99.99-doesnotexist` as the invalid image tag
3. Note the deployment has a previous healthy revision available
4. Select `RollbackDeployment` (confidence 0.95) over `CrashLoopRollback` (0.75)
5. Request human approval (critical severity in production)

### 7. Approve and verify remediation

```bash
# Approve the RAR
kubectl get rar -n kubernaut-system
kubectl patch rar <RAR_NAME> -n kubernaut-system --type=merge --subresource=status \
  -p '{"status":{"decision":"Approved","decidedBy":"human"}}'

# After approval:
kubectl get pods -n demo-rollout
# All 3 replicas Running with nginx:1.27-alpine (no ImagePullBackOff pods)

kubectl rollout history deployment/checkout-api -n demo-rollout
# REVISION  CHANGE-CAUSE
# 2         <none>        (bad image)
# 3         <none>        (rollback to revision 1)
```

## Cleanup

```bash
./scenarios/stuck-rollout/cleanup.sh
```

## Pipeline Timeline (OCP observed)

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy + baseline | T+0:00 | — |
| Inject bad image | T+0:15 | — |
| progressDeadlineSeconds exceeded | T+2:15 | 120 s deadline |
| KubeDeploymentRolloutStuck fires | T+6:08 | `for: 1m` + OCP scrape latency |
| RR created | T+6:11 | 3 s after alert |
| AA completes | T+7:43 | 91 s investigation (6 poll cycles) |
| Approval requested | T+7:43 | Immediate |
| Approved (manual) | T+9:43 | — |
| WFE completes (rollback) | T+10:13 | 30 s job execution |
| EA completes (healthScore=1) | T+11:13 | 60 s health check |
| **Total** | **~11 min** | (6 min waiting for alert on OCP) |

## BDD Specification

```gherkin
Feature: Stuck rollout remediation via deployment rollback

  Scenario: Non-existent image tag causes stuck rollout
    Given a deployment "checkout-api" in namespace "demo-rollout"
      And the deployment has 3 healthy replicas running nginx:1.27-alpine
      And progressDeadlineSeconds is 120s
      And the "rollback-deployment-v1" workflow is registered

    When the image is updated to "nginx:99.99.99-doesnotexist"
      And new pods enter ImagePullBackOff
      And the rollout exceeds progressDeadlineSeconds (120s)
      And the KubeDeploymentRolloutStuck alert fires (for: 1m)

    Then Gateway receives the alert via AlertManager webhook
      And Signal Processing enriches with severity=critical
      And HAPI diagnoses stuck rollout from invalid image tag
      And contributing factors include: invalid tag, config error, rolling update blocking
      And the LLM selects RollbackDeployment (confidence 0.95)
      And an alternative CrashLoopRollback is considered but rejected (0.75)
      And Approval is required (production environment, critical severity)
      And after approval, WFE runs "kubectl rollout undo"
      And the original nginx:1.27-alpine image is restored
      And all 3 replicas become Running/Ready
      And Effectiveness Monitor confirms healthScore=1
      And no ImagePullBackOff pods remain
```

## Acceptance Criteria

- [ ] Deployment starts healthy with 3 replicas (nginx:1.27-alpine)
- [ ] Bad image causes ImagePullBackOff on new ReplicaSet pods
- [ ] Old pods remain running (rolling update strategy preserves availability)
- [ ] Rollout exceeds progressDeadlineSeconds (120 s)
- [ ] KubeDeploymentRolloutStuck alert fires
- [ ] LLM selects RollbackDeployment (not CrashLoopRollback or other)
- [ ] Confidence >= 0.95
- [ ] Approval required (production + critical)
- [ ] Rollback restores original image (revision 3 = rollback to 1)
- [ ] All 3 replicas Running/Ready after rollback
- [ ] No ImagePullBackOff pods remain
- [ ] EA confirms healthScore=1
- [ ] Works on both Kind and OCP
