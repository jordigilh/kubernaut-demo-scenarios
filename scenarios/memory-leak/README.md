# Scenario #129: Proactive Memory Exhaustion

## Overview

Demonstrates Kubernaut's **proactive remediation** capability. Instead of waiting for
an OOM kill, Prometheus `predict_linear()` detects that a container's memory is growing
linearly and will exceed its limit within 30 minutes. Kubernaut intervenes with a
graceful rolling restart that resets memory before the crash occurs.

**Key differentiator**: The pod never crashes. Kubernaut acts on a *prediction*, not a symptom.

| | |
|---|---|
| **Signal** | `ContainerMemoryExhaustionPredicted` — `predict_linear()` projects OOM within 30 min |
| **Root cause** | `leaker` sidecar writes ~1 MB every 5 s to a memory-backed emptyDir |
| **Remediation** | `kubectl rollout restart` resets memory to baseline |

## Signal Flow

```
predict_linear(container_memory_working_set_bytes[5m], 1800)
  > kube_pod_container_resource_limits{resource="memory"}
  → ContainerMemoryExhaustionPredicted alert (severity: warning)
  → AlertManager webhook → Gateway → RemediationRequest
  → Signal Processing (severity=warning, env=production)
  → AI Analysis (HAPI + Claude Sonnet 4 on Vertex AI)
    → LLM identifies linear memory growth in "leaker" container
    → Contributing factors: continuous allocation, memory-backed emptyDir, unbounded writes
    → Selects GracefulRestart workflow (confidence 0.9)
    → Approval: not required (warning severity, auto-approved by policy)
  → WorkflowExecution: kubectl rollout restart deployment/leaky-app
  → Effectiveness Monitor: healthScore=1, memory reset to baseline
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With cAdvisor scraping and kube-state-metrics |
| Workflow catalog | `graceful-restart-v1` registered in DataStorage |
| HAPI Prometheus | Auto-enabled by `run.sh`, reverted by `cleanup.sh` ([manual enablement](../../docs/prometheus-toolset.md)) |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `graceful-restart-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `graceful-restart-v1-runner` |
| ClusterRoleBinding | `graceful-restart-v1-runner` |

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
./scenarios/memory-leak/run.sh
```

Options:
- `--interactive` — pause at approval step for manual approval
- `--no-validate` — skip the validation pipeline (deploy + inject only)

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/memory-leak/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Deploy the workload

```bash
kubectl apply -k scenarios/memory-leak/manifests/
kubectl wait --for=condition=Available deployment/leaky-app -n demo-memory-leak --timeout=120s
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/memory-leak/overlays/ocp/
kubectl wait --for=condition=Available deployment/leaky-app -n demo-memory-leak --timeout=120s
```

</details>

The deployment creates 2 replicas, each with:
- **app** container: nginx serving health checks
- **leaker** sidecar: writes 1 MB to a memory-backed emptyDir every 5 seconds (~12 MB/min)

#### 2. Verify healthy state

```bash
kubectl get pods -n demo-memory-leak
# NAME                        READY   STATUS    RESTARTS   AGE
# leaky-app-5df747bb-7msqr    2/2     Running   0          6s
# leaky-app-5df747bb-9llc5    2/2     Running   0          6s
```

#### 3. Observe memory growth

```bash
watch kubectl top pods -n demo-memory-leak --containers
```

The leaker container's memory climbs linearly at ~12 MB/min. The container has a
192 Mi memory limit, giving approximately 16 minutes before OOM under normal
conditions.

#### 4. Wait for the proactive alert

The `ContainerMemoryExhaustionPredicted` alert fires once `predict_linear()` projects
the leaker container will exceed its 192 Mi limit within 30 minutes. This typically
takes **3-4 minutes** of trend data on OCP (5-7 minutes on Kind due to slower
scrape intervals).

> [!NOTE]
> **OCP timing**: On OCP, `predict_linear()` may need 3-5 minutes of trend data
> before the alert fires, depending on cAdvisor scrape interval.

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  amtool alert query alertname=ContainerMemoryExhaustionPredicted --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=ContainerMemoryExhaustionPredicted --alertmanager.url=http://localhost:9093
```

</details>

#### 5. Monitor the Kubernaut pipeline

Once the alert fires, the full pipeline completes in ~3-4 minutes:

```bash
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

The LLM will:
1. Investigate the leaker container's memory growth pattern
2. Identify the root cause as continuous memory allocation to a memory-backed emptyDir
3. Identify contributing factors: unbounded file creation, no cleanup, emptyDir volume
4. Select `GracefulRestart` workflow (confidence 0.9) — a rolling restart resets memory
5. Auto-approve (warning severity does not require human approval per Rego policy)

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
| **Root Cause** | Intentional memory leak simulation in leaker container writing 1MB files every 5 seconds to memory-backed emptyDir volume, creating linear unbounded memory growth that will exhaust the 192Mi container limit and 256Mi volume limit. |
| **Severity** | critical |
| **Target Resource** | Deployment/leaky-app (ns: demo-memory-leak) |
| **Workflow Selected** | graceful-restart-v1 |
| **Confidence** | 0.95 |
| **Approval** | not required (staging, high confidence) |

**Key Reasoning Chain:**

1. Detects ContainerOOMKilling alert with OOMKilled termination reason.
2. Analyzes memory usage pattern relative to configured limits.
3. Selects memory limits increase to provide immediate relief.

> **Why this matters**: Shows the LLM diagnosing OOM events and selecting resource limit adjustment. Note: for true memory leaks with unbounded growth, the LLM should eventually escalate to manual review after repeated ineffective remediations.

#### 7. Verify remediation

After the workflow execution completes:

```bash
kubectl get pods -n demo-memory-leak
# All pods Running/Ready — memory usage back near baseline

kubectl rollout history deployment/leaky-app -n demo-memory-leak
# REVISION  CHANGE-CAUSE
# 1         <none>        (initial deploy)
# 2         <none>        (rolling restart by WFE)
```

Note: The leaker sidecar resumes allocating memory after restart. In a real-world
scenario, the root cause fix (removing the leak) would be a separate action. The
`validate.sh` script patches out the leaker sidecar after remediation to prevent
the alert from re-firing.

#### 8. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Cleanup

```bash
./scenarios/memory-leak/cleanup.sh
```

## Pipeline Timeline (OCP observed)

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy + baseline | T+0:00 | — |
| Alert fires | T+3:38 | 3 min 38 s of trend data |
| RR created | T+3:42 | 4 s after alert |
| AA completes | T+5:34 | 1 min 52 s investigation (106 s, 7 poll cycles) |
| WFE completes | T+6:01 | 27 s job execution |
| EA completes | T+7:01 | 60 s health check window |
| **Total** | **~7 min** | |

## BDD Specification

```gherkin
Feature: Proactive memory exhaustion remediation

  Scenario: predict_linear detects OOM trend before crash
    Given a deployment "leaky-app" in namespace "demo-memory-leak"
      And the "leaker" sidecar writes ~1 MB every 5 s to a memory-backed emptyDir
      And the container has a 192 Mi memory limit
      And Prometheus is scraping cAdvisor metrics

    When container_memory_working_set_bytes grows linearly
      And predict_linear() projects the limit will be exceeded within 30 minutes
      And the ContainerMemoryExhaustionPredicted alert fires

    Then Gateway receives the alert via AlertManager webhook
      And Signal Processing enriches with severity=warning
      And HAPI diagnoses linear memory growth in the "leaker" container
      And contributing factors include: continuous allocation, memory-backed emptyDir
      And the LLM selects GracefulRestart workflow (confidence 0.9)
      And Rego policy auto-approves (warning severity, no human review required)
      And WorkflowExecution runs "kubectl rollout restart deployment/leaky-app"
      And pods restart with memory reset to baseline
      And Effectiveness Monitor confirms healthScore=1
      And no pod experienced an OOM kill during the demo
```

## Acceptance Criteria

- [ ] `predict_linear()` alert fires before any OOM kill
- [ ] LLM correctly identifies the linear memory growth pattern
- [ ] Contributing factors include memory-backed emptyDir and unbounded writes
- [ ] `GracefulRestart` workflow is selected (not scale-up or other action)
- [ ] Confidence >= 0.9
- [ ] Approval not required (auto-approved by Rego policy for warning severity)
- [ ] Rolling restart completes without downtime (2 replicas, rolling update)
- [ ] Memory usage drops back near baseline after restart
- [ ] Deployment shows >1 revision (restart occurred)
- [ ] EM confirms healthScore=1
- [ ] No pod in the namespace experienced an OOM kill during the demo
- [ ] Works on both Kind and OCP
