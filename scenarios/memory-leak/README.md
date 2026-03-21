# Scenario #129: Proactive Memory Exhaustion

## Overview

Demonstrates Kubernaut's **proactive remediation** capability. Instead of waiting for
an OOM kill, Prometheus `predict_linear()` detects that a container's memory is growing
linearly and will exceed its limit within 30 minutes. Kubernaut intervenes with a
graceful rolling restart that resets memory before the crash occurs.

**Key differentiator**: The pod never crashes. Kubernaut acts on a *prediction*, not a symptom.

**Signal**: `ContainerMemoryExhaustionPredicted` — `predict_linear()` projects OOM within 30 min
**Root cause**: `leaker` sidecar writes ~1 MB every 5 s to a memory-backed emptyDir
**Remediation**: `kubectl rollout restart` resets memory to baseline

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
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With cAdvisor scraping and kube-state-metrics |
| Workflow catalog | `graceful-restart-v1` registered in DataStorage |
| HAPI Prometheus | Auto-enabled by `run.sh`, reverted by `cleanup.sh` (#108) |

## Automated Run

```bash
./scenarios/memory-leak/run.sh
```

Options:
- `--interactive` — pause at approval step for manual approval
- `--no-validate` — skip the validation pipeline (deploy + inject only)

## Manual Step-by-Step

### 1. Deploy the workload

```bash
kubectl apply -k scenarios/memory-leak/manifests/
kubectl wait --for=condition=Available deployment/leaky-app -n demo-memory-leak --timeout=120s
```

The deployment creates 2 replicas, each with:
- **app** container: nginx serving health checks
- **leaker** sidecar: writes 1 MB to a memory-backed emptyDir every 5 seconds (~12 MB/min)

### 2. Verify healthy state

```bash
kubectl get pods -n demo-memory-leak
# NAME                        READY   STATUS    RESTARTS   AGE
# leaky-app-5df747bb-7msqr    2/2     Running   0          6s
# leaky-app-5df747bb-9llc5    2/2     Running   0          6s
```

### 3. Observe memory growth

```bash
watch kubectl top pods -n demo-memory-leak --containers
```

The leaker container's memory climbs linearly at ~12 MB/min. The container has a
192 Mi memory limit, giving approximately 16 minutes before OOM under normal
conditions.

### 4. Wait for the proactive alert

The `ContainerMemoryExhaustionPredicted` alert fires once `predict_linear()` projects
the leaker container will exceed its 192 Mi limit within 30 minutes. This typically
takes **3-4 minutes** of trend data on OCP (5-7 minutes on Kind due to slower
scrape intervals).

```bash
# Check alert status
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# open http://localhost:9090/alerts
```

### 5. Monitor the Kubernaut pipeline

Once the alert fires, the full pipeline completes in ~3-4 minutes:

```bash
kubectl get rr,sp,aa,we,ea -n kubernaut-system
```

The LLM will:
1. Investigate the leaker container's memory growth pattern
2. Identify the root cause as continuous memory allocation to a memory-backed emptyDir
3. Identify contributing factors: unbounded file creation, no cleanup, emptyDir volume
4. Select `GracefulRestart` workflow (confidence 0.9) — a rolling restart resets memory
5. Auto-approve (warning severity does not require human approval per Rego policy)

### 6. Verify remediation

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
