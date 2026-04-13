# Scenario #128: SLO Error Budget Burn -> Proactive Rollback

## Overview

This scenario demonstrates Kubernaut detecting that a service is burning its SLO error
budget at an unsustainable rate and proactively rolling back the deployment to preserve
the SLO before it breaches.

This is arguably the **highest enterprise-value** demo scenario because it connects
**business objectives** (SLOs) directly to automated remediation. The LLM adds unique
value by:

- Correlating the error budget burn timing with the most recent deployment revision
- Reasoning about which revision caused the degradation
- Choosing rollback to the specific revision that introduced the errors
- Distinguishing between: bad deploy (rollback), traffic spike (scale out),
  dependency failure (wait)
- Explaining in the audit trail: *"Error budget burning at 14x sustainable rate since
  revision N. Rolling back to preserve SLO."*

## Signal Flow

```
blackbox-exporter  ──probe──>  api-gateway /api/status
        │
        ▼
   probe_success{namespace="demo-slo"} = 0          (scraped every 10s)
        │
        ▼
   Recording rule:
     job:api_gateway:error_rate_5m =
       1 - avg_over_time(probe_success{namespace="demo-slo", instance=~".*api-gateway.*"}[5m])
        │
        ▼
   Alert:  ErrorBudgetBurn
     expr:  job:api_gateway:error_rate_5m > (0.001 * 14.4)   # >1.44% error rate
     for:   3m
     labels:
       severity: critical
       deployment: api-gateway
```

## Failure Mode

The injection is realistic: a **bad api-gateway ConfigMap** (`api-config-bad`) that returns
500 on `/api/` but passes health checks (`/healthz` returns 200). This mirrors a real
production issue where readiness probes pass but the service is functionally broken.

The threshold (14.4x burn rate) means the 0.1% error budget would exhaust in ~1 hour
at the observed rate.

## LLM Analysis (OCP observed)

| Field | Value |
|-------|-------|
| Root Cause | `api-gateway deployment using misconfigured ConfigMap 'api-config-bad' that explicitly returns HTTP 500 errors for all /api/ requests` |
| Severity | `critical` |
| Confidence | 0.9 |
| Selected Workflow | `RollbackDeployment` (crashloop-rollback-v1) |
| Alternative | `crashloop-rollback-risk-v1` (confidence 0.75) — risk-averse variant |
| Approval | **Required** — production environment (`run.sh` enforces deterministic approval) |
| Contributing Factors | Misconfigured application configuration, Bad ConfigMap deployment |

The LLM correctly identifies `api-config-bad` as the root cause and selects
`RollbackDeployment` over the risk-averse variant because the configuration issue is
clear-cut and warrants a direct rollback.

## Prerequisites

- Kubernetes / OpenShift cluster with Prometheus Operator (CRD: Probe, PrometheusRule)
- Kubernaut services deployed with HAPI configured for a real LLM backend
- HolmesGPT Prometheus toolset (auto-enabled by `run.sh`, reverted by `cleanup.sh` — [manual enablement](../../docs/prometheus-toolset.md))
- `RollbackDeployment` action type registered
- `crashloop-rollback-v1` (or equivalent) workflow in the catalog

> **OCP note**: The scenario deploys its own blackbox-exporter in the `demo-slo`
> namespace — no cluster-level blackbox installation is required. The OCP overlay
> (`overlays/ocp/`) applies cluster integration patches (for example PrometheusRule
> and ServiceMonitor release labels, and Namespace `cluster-monitoring`); the
> `demo-http-server` image is platform-neutral (listens on port 8080 by default).

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `proactive-rollback-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `proactive-rollback-v1-runner` |
| ClusterRoleBinding | `proactive-rollback-v1-runner` |

**Permissions**:

| API group | Resources | Verbs |
|-----------|-----------|-------|
| apps | deployments | get, list, patch, update |
| apps | replicasets | get, list |
| core | pods | get, list |

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
bash scenarios/slo-burn/run.sh                # interactive — pauses at approval gate
bash scenarios/slo-burn/run.sh --auto-approve  # auto-approve (requires #57 fix)
bash scenarios/slo-burn/run.sh --no-validate   # deploy + inject only, skip pipeline
```

| Flag | Behaviour |
|------|-----------|
| *(none)* | Deploy, inject, wait for alert, poll pipeline, pause at approval |
| `--auto-approve` | Same but patches RAR automatically |
| `--no-validate` | Deploy + inject only; useful for manual observation |

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
bash scenarios/slo-burn/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Deploy namespace, ConfigMap, API gateway, traffic-gen, blackbox, and Prometheus rules

```bash
kubectl apply -k scenarios/slo-burn/manifests/
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/slo-burn/overlays/ocp/
```

</details>

#### 2. Wait for pods

```bash
kubectl wait --for=condition=Available deployment/api-gateway \
  deployment/blackbox-exporter deployment/traffic-gen \
  -n demo-slo --timeout=60s
```

#### 3. Establish healthy baseline (~30s)

```bash
sleep 30
```

#### 4. Inject bad config

```bash
bash scenarios/slo-burn/inject-bad-config.sh
```

#### 5. Watch error rate climb

Prometheus: `job:api_gateway:error_rate_5m` should approach ~1.0. The alert fires after the 3-minute `for:` duration.

#### 6. Query Alertmanager and watch the pipeline

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert query alertname=ErrorBudgetBurn --alertmanager.url=http://localhost:9093

watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

<details>
<summary><strong>OCP (amtool)</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=ErrorBudgetBurn --alertmanager.url=http://localhost:9093
```

</details>

#### 7. Inspect AI Analysis

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

#### Expected LLM Reasoning (v1.2 baseline)

When Kubernaut's AI analysis processes this scenario, the LLM typically reasons as follows:

| Field | Expected Value |
|-------|---------------|
| **Root Cause** | ErrorBudgetBurn caused by misconfigured ConfigMap 'api-config-bad' that returns HTTP 500 errors for all API endpoints. The deployment was recently updated to use this faulty ConfigMap instead of the working 'api-config' ConfigMap. Traffic generator is continuously receiving 500 responses, causing SLO degradation. |
| **Severity** | high |
| **Target Resource** | Deployment/api-gateway (ns: demo-slo) |
| **Workflow Selected** | proactive-rollback-v1 |
| **Confidence** | 0.95 |
| **Approval** | required (production environment) |

**Key Reasoning Chain:**

1. Detects ErrorBudgetBurn alert based on error rate SLI.
2. Identifies recent deployment change correlating with error rate increase.
3. Selects proactive rollback to restore the last known-good revision before the error budget is fully exhausted.

> **Why this matters**: Shows the LLM handling proactive SLO-based signals (not just crash/failure signals) and correlating error budget burn with recent deployment changes.

#### 8. Approve when prompted (production environment)

```bash
kubectl patch remediationapprovalrequest <RAR> -n kubernaut-system \
  --type merge --subresource status \
  -p '{"status":{"decision":"Approved","decidedBy":"<you>","decidedAt":"<now>"}}'
```

#### 9. Verify rollback

```bash
kubectl rollout history deployment/api-gateway -n demo-slo
kubectl get pods -n demo-slo
```

#### 10. Cleanup

```bash
bash scenarios/slo-burn/cleanup.sh
```

#### 11. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Pipeline Timeline (OCP observed)

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy + baseline | T+0:00 | — |
| Fault injection (bad ConfigMap) | T+0:30 | 30 s baseline |
| ErrorBudgetBurn alert fires | T+3:33 | 3 min `for:` duration |
| RR created | T+3:37 | 4 s after alert |
| AA completes (7 poll cycles, 105 s) | T+5:22 | 1 min 45 s investigation |
| Manual approval | T+17:20 | *waited for operator* |
| WFE completes (rollout undo, 11 s) | T+17:31 | 11 s job |
| EA completes (healthScore = 1.0) | T+18:31 | 60 s health check |
| **Total (excl. approval wait)** | **~7 min** | |

## Cleanup

```bash
bash scenarios/slo-burn/cleanup.sh
```

## BDD Specification

```gherkin
Feature: SLO Error Budget Burn -> Proactive Rollback

  Scenario: Error budget burning at unsustainable rate triggers proactive rollback
    Given an api-gateway Deployment with 2 replicas in demo-slo namespace
      And a blackbox-exporter Probe targeting /api/status every 10s
      And a traffic generator sending steady requests to /api/status
      And the service is healthy with ~0% error rate (SLO: 99.9%)
      And the Kubernaut pipeline is active with a real LLM
      And the "crashloop-rollback-v1" workflow is registered in the catalog

    When a bad ConfigMap (api-config-bad) is deployed returning 500 on /api/
      And the Deployment is patched to reference api-config-bad
      And the rollout completes (health checks /healthz still pass)
      And the 5-minute rolling error rate exceeds 1.44% (14.4x burn rate)

    Then ErrorBudgetBurn alert fires after the 3-minute for: duration
      And a RemediationRequest is created for Deployment/api-gateway
      And the LLM identifies "api-config-bad" ConfigMap as root cause
      And the LLM selects RollbackDeployment with confidence >= 0.9
      And Rego policy requires manual approval (production environment)
      And after approval the WFE Job runs "kubectl rollout undo"
      And the deployment reverts to the previous revision (api-config)
      And EffectivenessAssessment reports healthScore = 1.0
      And the RR outcome is "Remediated"
```

## Acceptance Criteria

- [x] API gateway + ConfigMap + traffic generator + blackbox-exporter manifests
- [x] Injection script to deploy bad config (platform-aware: port 80 / 8080)
- [x] Prometheus Probe CRD + SLO burn rate PrometheusRule
- [x] OCP overlay patches (PrometheusRule release label, ServiceMonitor release label, Namespace cluster-monitoring)
- [x] Full pipeline with real LLM: Gateway -> SP -> AA -> WE -> EA
- [x] LLM correlates error spike with ConfigMap change and selects rollback
- [x] EffectivenessAssessment healthScore = 1.0, outcome = Remediated
- [x] Approval gate enforced (production environment, critical severity)

## Notes

- **Readiness vs. Functionality**: The `/healthz` endpoint still returns 200 while
  `/api/` returns 500. This is a realistic production failure mode where health checks
  pass but the service is functionally broken.
- **Shared Rollback**: The remediation action (`kubectl rollout undo`) is the same as
  #120 (CrashLoopBackOff). The difference is the trigger (SLO burn rate vs. pod crash)
  and the LLM's reasoning (business objective vs. health check).
- **Multi-arch workflow image**: The `crashloop-rollback-job` image must be a
  multi-arch manifest (amd64 + arm64). An arm64-only build will fail with
  `Exec format error` on amd64 clusters.
