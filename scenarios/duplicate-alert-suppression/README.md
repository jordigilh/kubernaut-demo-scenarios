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

| | |
|---|---|
| **Signal** | `KubePodCrashLooping` — 5 pods crashing, same Deployment owner |
| **Deduplication** | OwnerResolver fingerprint → `SHA256(namespace:deployment:api-gateway)` |
| **Result** | 1 RR (not 5), `occurrenceCount >= 2` |
| **Remediation** | `RollbackDeployment` restores previous healthy revision |

## Signal Flow

```
5 pods crash (invalid app config) → 5 KubePodCrashLooping alerts
  → AlertManager groups by namespace → 2+ webhook payloads
  → Gateway OwnerResolver: each pod → Deployment/api-gateway
  → Single fingerprint: SHA256(demo-alert-storm:deployment:api-gateway)
  → 1 RemediationRequest (occurrenceCount increments per webhook)
  → Signal Processing
  → AI Analysis (HAPI + Claude Sonnet 4 on Vertex AI)
    → Root cause: invalid directive in ConfigMap gateway-config-bad
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
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics scraping |
| Workflow catalog | `rollback-deployment-v1` registered in DataStorage |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`). It uses the `rollback-deployment-v1` workflow from the
stuck-rollout scenario:

| Resource | Name |
|----------|------|
| ServiceAccount | `rollback-deployment-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `rollback-deployment-v1-runner` |
| ClusterRoleBinding | `rollback-deployment-v1-runner` |

**Permissions**:

| API group | Resource | Verbs |
|-----------|----------|-------|
| `apps` | deployments | get, list, patch, update |
| `apps` | replicasets | get, list |
| core | pods | get, list |

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
./scenarios/duplicate-alert-suppression/run.sh
```

Options:
- `--interactive` — pause at approval step for manual approval
- `--no-validate` — skip the validation pipeline (deploy + inject only)

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/duplicate-alert-suppression/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Deploy the workload

```bash
kubectl apply -k scenarios/duplicate-alert-suppression/manifests/

kubectl wait --for=condition=Available deployment/api-gateway \
  -n demo-alert-storm --timeout=120s
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/duplicate-alert-suppression/overlays/ocp/

kubectl wait --for=condition=Available deployment/api-gateway \
  -n demo-alert-storm --timeout=120s
```

</details>

This creates a 5-replica `api-gateway` Deployment running `demo-http-server:1.0.0`,
a healthy ConfigMap, a Service, a ServiceMonitor, and a PrometheusRule that fires
`KubePodCrashLooping` when `increase(kube_pod_container_status_restarts_total[10m]) > 3`.

#### 2. Verify healthy state

```bash
kubectl get pods -n demo-alert-storm
# NAME                          READY   STATUS    RESTARTS   AGE
# api-gateway-dd576bb49-5hf9b   1/1     Running   0          7s
# api-gateway-dd576bb49-7qgmz   1/1     Running   0          7s
# api-gateway-dd576bb49-9pnqt   1/1     Running   0          7s
# api-gateway-dd576bb49-kx562   1/1     Running   0          7s
# api-gateway-dd576bb49-srk4g   1/1     Running   0          7s
```

#### 3. Inject bad configuration (all 5 pods crash)

```bash
bash scenarios/duplicate-alert-suppression/inject-bad-config.sh
```

The script creates a `gateway-config-bad` ConfigMap with an `invalid_directive` flag
and patches the deployment to reference it. The demo-http-server detects this on startup
and exits with `[emerg]`. All 5 pods crash simultaneously:

```bash
kubectl get pods -n demo-alert-storm
# 3 new pods in CrashLoopBackOff, 4 old pods still Running (rolling update)
```

#### 4. Wait for alert burst

Prometheus fires 5 individual `KubePodCrashLooping` alerts (one per pod).
AlertManager groups them by namespace and sends 2+ webhook payloads to the Gateway.

The Gateway's OwnerResolver resolves each pod to `Deployment/api-gateway` and
produces a single fingerprint. Only **1 RR** is created:

```bash
kubectl get rr -n kubernaut-system -o wide
# Only 1 RR for demo-alert-storm (not 5)
```

#### 5. Monitor the pipeline

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
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

The LLM will:
1. Investigate the crashing pods and read container error logs
2. Identify the `invalid_directive` in `gateway-config-bad`
3. Note it was introduced in deployment revision 2
4. Select `RollbackDeployment` (confidence 0.95)
5. Consider a risk-averse `CrashLoopRollback` alternative (0.85) but reject it
6. Auto-approve (policy does not require manual approval)

#### 6. Inspect AI Analysis

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

#### Expected LLM Reasoning (v1.2 baseline)

When Kubernaut's AI analysis processes this scenario, the LLM typically reasons as follows:

| Field | Expected Value |
|-------|---------------|
| **Root Cause** | Pod crashes due to invalid configuration directive 'invalid_directive: true' in ConfigMap gateway-config-bad. Application fails to parse config file and exits with code 1, causing CrashLoopBackOff. |
| **Severity** | critical |
| **Target Resource** | Deployment/api-gateway (ns: demo-alert-storm) |
| **Workflow Selected** | crashloop-rollback-v1 |
| **Confidence** | 0.90 |
| **Approval** | not required (staging, high confidence) |

**Key Reasoning Chain:**

1. Detects CrashLoopBackOff from invalid config.
2. Traces crash to ConfigMap with bad directive.
3. Selects appropriate fix workflow.
4. **Key**: When duplicate alerts fire for the same root cause, the platform suppresses redundant RemediationRequests — only the first alert triggers the pipeline.

> **Why this matters**: Shows both the LLM's config-crash diagnosis and the platform's duplicate alert suppression mechanism preventing redundant remediation attempts.

#### 7. Verify remediation and deduplication

```bash
# All 5 pods recovered via a single rollback
kubectl get pods -n demo-alert-storm
# 5 pods Running with demo-http-server:1.0.0

# Deduplication stats on the single RR
kubectl get rr <RR_NAME> -n kubernaut-system \
  -o jsonpath='{.status.deduplication}'
# {"firstSeenAt":"...","lastSeenAt":"...","occurrenceCount":2}

# No blocked duplicate RRs — dedup happened at fingerprint level
kubectl get rr -n kubernaut-system -o wide | grep demo-alert-storm
# Only 1 row
```

#### 8. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

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

    When an invalid app config is injected via ConfigMap swap
      And all 5 pods enter CrashLoopBackOff simultaneously
      And Prometheus fires 5 KubePodCrashLooping alerts (one per pod)

    Then AlertManager groups the alerts and sends 2+ webhook payloads
      And Gateway OwnerResolver maps each pod to Deployment/api-gateway
      And a single fingerprint is computed for all 5 alerts
      And exactly 1 RemediationRequest is created (not 5)
      And the RR's deduplication.occurrenceCount reflects webhook deliveries
      And HAPI diagnoses invalid config directive in gateway-config-bad
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
