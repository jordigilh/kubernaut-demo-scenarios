# Scenario #170: Duplicate Alert Suppression

## Overview

Demonstrates Gateway-level **deduplication via OwnerResolver fingerprinting**. When
5 pods from the same Deployment crash simultaneously, Prometheus fires per-pod
`KubePodCrashLooping` alerts. AlertManager groups them and delivers multiple webhook
payloads. The Gateway's OwnerResolver maps each pod alert to its owning Deployment,
producing a single fingerprint. Instead of creating 5 RemediationRequests, the Gateway
creates **1 RR** with an incrementing `occurrenceCount`.

This proves Kubernaut doesn't waste LLM tokens, workflow executions, or human attention
on duplicate incidents — a critical requirement for noisy production environments.

**Signal**: `KubePodCrashLooping` — 5 pods crashing, same Deployment owner
**Deduplication**: OwnerResolver fingerprint → `SHA256(namespace:deployment:api-gateway)`
**Result**: 1 RR (not 5), `occurrenceCount >= 2`
**Remediation**: `RollbackDeployment` restores previous healthy revision

## Signal Flow

```
5 pods crash (invalid nginx config) → 5 KubePodCrashLooping alerts
  → AlertManager groups by namespace → 2+ webhook payloads
  → Gateway OwnerResolver: each pod → Deployment/api-gateway
  → Single fingerprint: SHA256(demo-alert-storm:deployment:api-gateway)
  → 1 RemediationRequest (occurrenceCount increments per webhook)
  → Signal Processing
  → AI Analysis (HAPI + Claude Sonnet 4 on Vertex AI)
    → Root cause: invalid nginx directive in ConfigMap gateway-config-bad
    → Contributing factors: bad config, recent deployment change, no config validation
    → Selected: RollbackDeployment (confidence 0.95)
    → Alternative considered: risk-averse CrashLoopRollback (0.85, rejected — medium risk tolerance)
    → Approval: not required (auto-approved by policy)
  → WorkflowExecution: kubectl rollout undo deployment/api-gateway
  → Effectiveness Monitor: healthScore=1 (all 5 replicas Running)
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
./scenarios/duplicate-alert-suppression/run.sh
```

Options:
- `--interactive` — pause at approval step for manual approval
- `--no-validate` — skip the validation pipeline (deploy + inject only)

## Manual Step-by-Step

### 1. Deploy the workload

```bash
kubectl apply -k scenarios/duplicate-alert-suppression/manifests/
kubectl wait --for=condition=Available deployment/api-gateway \
  -n demo-alert-storm --timeout=120s
```

This creates a 5-replica `api-gateway` Deployment running `nginx:1.27-alpine`,
a healthy ConfigMap, a Service, and a PrometheusRule that fires
`KubePodCrashLooping` when `increase(kube_pod_container_status_restarts_total[10m]) > 3`.

### 2. Verify healthy state

```bash
kubectl get pods -n demo-alert-storm
# NAME                          READY   STATUS    RESTARTS   AGE
# api-gateway-dd576bb49-5hf9b   1/1     Running   0          7s
# api-gateway-dd576bb49-7qgmz   1/1     Running   0          7s
# api-gateway-dd576bb49-9pnqt   1/1     Running   0          7s
# api-gateway-dd576bb49-kx562   1/1     Running   0          7s
# api-gateway-dd576bb49-srk4g   1/1     Running   0          7s
```

### 3. Inject bad configuration (all 5 pods crash)

```bash
bash scenarios/duplicate-alert-suppression/inject-bad-config.sh
```

The script creates a `gateway-config-bad` ConfigMap with an invalid nginx directive
and patches the deployment to reference it. All 5 pods crash simultaneously:

```bash
kubectl get pods -n demo-alert-storm
# 3 new pods in CrashLoopBackOff, 4 old pods still Running (rolling update)
```

### 4. Wait for alert storm

Prometheus fires 5 individual `KubePodCrashLooping` alerts (one per pod).
AlertManager groups them by namespace and sends 2+ webhook payloads to the Gateway.

The Gateway's OwnerResolver resolves each pod to `Deployment/api-gateway` and
produces a single fingerprint. Only **1 RR** is created:

```bash
kubectl get rr -n kubernaut-system
# Only 1 RR for demo-alert-storm (not 5)
```

### 5. Monitor the pipeline

```bash
kubectl get rr,sp,aa,we,ea -n kubernaut-system
```

The LLM will:
1. Investigate the crashing pods and read nginx error logs
2. Identify the `invalid_directive_that_breaks_nginx` in `gateway-config-bad`
3. Note it was introduced in deployment revision 2
4. Select `RollbackDeployment` (confidence 0.95)
5. Consider a risk-averse `CrashLoopRollback` alternative (0.85) but reject it
6. Auto-approve (policy does not require manual approval)

### 6. Verify remediation and deduplication

```bash
# All 5 pods recovered via a single rollback
kubectl get pods -n demo-alert-storm
# 5 pods Running with nginx:1.27-alpine

# Deduplication stats on the single RR
kubectl get rr <RR_NAME> -n kubernaut-system \
  -o jsonpath='{.status.deduplication}'
# {"firstSeenAt":"...","lastSeenAt":"...","occurrenceCount":2}

# No blocked duplicate RRs — dedup happened at fingerprint level
kubectl get rr -n kubernaut-system -o wide | grep demo-alert-storm
# Only 1 row
```

## Platform Notes

### OCP

The `run.sh` script auto-detects the platform and applies the `overlays/ocp/` kustomization via `get_manifest_dir()`. The overlay:

- Adds `openshift.io/cluster-monitoring: "true"` to the demo namespace
- Swaps `nginx:1.27-alpine` to `nginxinc/nginx-unprivileged:1.27-alpine`
- Removes the `release` label from `PrometheusRule`

No manual steps required.

## Cleanup

```bash
./scenarios/duplicate-alert-suppression/cleanup.sh
```

## Pipeline Timeline (OCP observed)

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy + baseline | T+0:00 | — |
| Inject bad config (all 5 pods) | T+0:20 | — |
| 5 pods enter CrashLoopBackOff | T+0:31 | 11 s after injection |
| KubePodCrashLooping alert fires | T+6:33 | ~6 min (OCP scrape latency) |
| RR created (1 RR, not 5) | T+6:40 | 7 s after alert |
| AA completes | T+8:07 | 90 s investigation (6 poll cycles) |
| Auto-approved (no RAR needed) | T+8:07 | Immediate |
| WFE completes (rollback) | T+8:35 | 28 s job execution |
| EA completes (healthScore=1) | T+9:24 | 49 s health check |
| **Total** | **~10 min** | (6 min waiting for alert on OCP) |

## Deduplication Mechanics

The Gateway's OwnerResolver is the key component:

1. Each webhook payload contains a pod-level alert (e.g., `pod=api-gateway-xxx`)
2. The OwnerResolver traverses the ownership chain: Pod → ReplicaSet → Deployment
3. The fingerprint is computed as `SHA256(namespace:kind:name)` from the Deployment
4. All 5 pod alerts resolve to the same fingerprint
5. The first webhook creates the RR; subsequent ones increment `occurrenceCount`

Note: `occurrenceCount` reflects **webhook deliveries**, not individual pod alerts.
AlertManager groups alerts before delivery, so 5 pod alerts may arrive as 2-3
grouped payloads. The exact count depends on AlertManager's `group_wait` and
`group_interval` settings.

## BDD Specification

```gherkin
Feature: Duplicate alert suppression via OwnerResolver fingerprinting

  Scenario: 5 crashing pods produce 1 RemediationRequest
    Given a deployment "api-gateway" in namespace "demo-alert-storm"
      And the deployment has 5 healthy replicas
      And the "rollback-deployment-v1" workflow is registered

    When an invalid nginx config is injected via ConfigMap swap
      And all 5 pods enter CrashLoopBackOff simultaneously
      And Prometheus fires 5 KubePodCrashLooping alerts (one per pod)

    Then AlertManager groups the alerts and sends 2+ webhook payloads
      And Gateway OwnerResolver maps each pod to Deployment/api-gateway
      And a single fingerprint is computed for all 5 alerts
      And exactly 1 RemediationRequest is created (not 5)
      And the RR's deduplication.occurrenceCount reflects webhook deliveries
      And HAPI diagnoses invalid nginx config in gateway-config-bad
      And the LLM selects RollbackDeployment (confidence 0.95)
      And auto-approval is granted (no manual review required)
      And WorkflowExecution rolls back the deployment
      And all 5 pods recover from a single rollback operation
      And Effectiveness Monitor confirms healthScore=1
```

## Acceptance Criteria

- [ ] 5 replicas deploy and become healthy
- [ ] Bad config causes all 5 pods to CrashLoopBackOff simultaneously
- [ ] Exactly 1 active (non-blocked) RR is created for the namespace
- [ ] RR deduplication.occurrenceCount > 1 (multiple webhooks deduplicated)
- [ ] 0 blocked duplicate RRs (dedup at fingerprint level, not post-creation)
- [ ] LLM selects RollbackDeployment (confidence >= 0.95)
- [ ] Auto-approved (no RAR created)
- [ ] All 5 pods Running/Ready after a single rollback
- [ ] EA confirms healthScore=1
- [ ] Works on both Kind and OCP
