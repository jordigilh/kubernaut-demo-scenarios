# Scenario: Severity Misdirection

> **Environment: OCP only.** Tests the LLM's ability to prioritize temporal
> causation over alert severity when a high-severity symptom masks a low-severity
> root cause.

## Overview

PostgreSQL is OOM-killed due to insufficient memory (warning severity). The
dependent api-gateway loses its database connection and starts crash-looping
(critical severity). Two alerts fire with different severities, and two
RemediationRequests are created with different signal fingerprints.

The LLM must recognize that the critical `KubePodCrashLooping` alert is a
**symptom** of the warning-level `ContainerOOMKilling`, and identify
`Deployment/postgres` as the root cause -- not the louder crash-looping
api-gateway.

This scenario validates that the LLM uses **temporal reasoning** (which alert
fired first and what caused what) rather than **severity ranking** (which alert
is louder).

## ITIL Classification

| Field | Value |
|-------|-------|
| **ITIL Level** | L3 -- Advanced Diagnostics |
| **Category** | Reactive / Severity Triage |
| **Signal** | `ContainerOOMKilling` (warning) + `KubePodCrashLooping` (critical) |
| **ActionType** | `RollbackDeployment` or `IncreaseMemoryLimits` (existing) |
| **Workflow** | `rollback-deployment-v1` / `increase-memory-limits-v1` (existing) |

## Architecture

```
postgres (memory limit: 256Mi → 16Mi)          api-gateway
         |                                           |
    [OOM injected]                             depends on postgres
    memory limit 16Mi                                |
    cannot initialize                                |
    OOM-killed                                  loses PG conn
         |                                      crash-loops
         |                                           |
  ContainerOOMKilling                      KubePodCrashLooping
  severity: warning                        severity: critical
  fires FIRST                              fires SECOND
         |                                           |
     RR #1 (warning)                            RR #2 (critical)
         |                                           |
    AI Analysis #1                           AI Analysis #2
         |                                           |
    remediationTarget:                       remediationTarget:
    Deployment/postgres                      Deployment/postgres (ideal)
    (OOM is root cause)                      Deployment/api-gateway (misdirected)
```

## Severity Misdirection Challenge

The misdirection occurs because:

1. The `KubePodCrashLooping` alert fires with **critical** severity
2. The `ContainerOOMKilling` alert fires with **warning** severity
3. A naive LLM would prioritize the critical alert and target api-gateway
4. The correct reasoning: postgres was OOM-killed **first**, causing the
   api-gateway to lose connectivity and crash-loop **second**

The LLM should examine:
- Pod events showing OOMKilled on the postgres container
- Timeline: postgres OOM preceded the api-gateway crash-loop
- App logs: api-gateway shows "Cannot connect to postgres" (it's a victim)
- Postgres pod status: OOMKilled, not a connectivity issue

## Fault Injection

`inject-oom.sh` patches the postgres Deployment memory limit:
```
resources.limits.memory: 256Mi → 16Mi
resources.requests.memory: 128Mi → 16Mi
```

PostgreSQL cannot initialize with 16Mi and is immediately OOM-killed by the
kernel. The rollback workflow reverts to the previous resource spec.

## Validation

| Assertion | Expected |
|-----------|----------|
| ContainerOOMKilling alert | Fires (warning severity) |
| KubePodCrashLooping alert | Fires (critical severity) |
| RR count | >= 1 |
| AA RCA target name | `postgres` (ideal) |
| AA RCA target kind | `Deployment` |
| RCA mentions OOM/memory | Yes (temporal reasoning) |

### Multi-Path Outcomes

| Path | RCA Target | Reasoning | Grade |
|------|------------|-----------|-------|
| A (ideal) | `Deployment/postgres` | Temporal causation: OOM preceded crash-loop | Pass |
| B (misdirected) | `Deployment/api-gateway` | Severity ranking: chased the critical alert | Fail (severity-misled) |
| C (acceptable) | Other target | Mixed reasoning | Pass with warning |
| D (acceptable) | N/A (escalated) | Insufficient confidence | Pass |

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | OCP with Kubernaut services deployed |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | With kube-state-metrics for OOMKilled reason and restart counts |
| Workflow catalog | `rollback-deployment-v1` or `increase-memory-limits-v1` registered |
| Images | `quay.io/sclorg/postgresql-16-c9s` (OCP) |

### Workflow RBAC

This scenario reuses existing deployment rollback or memory limit workflows.
No additional RBAC needed.

### Pre-flight checklist

```bash
# 1. Verify rollback/memory workflows are registered
kubectl get remediationworkflow -n kubernaut-system | grep -E 'rollback|memory'

# 2. Verify OOMKilled metric is available
kubectl exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=kube_pod_container_status_last_terminated_reason' \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'{len(r[\"data\"][\"result\"])} series')"
```

## Usage

```bash
# Run with auto-approval
./scenarios/severity-misdirection/run.sh --auto-approve

# Run with manual approval gate
./scenarios/severity-misdirection/run.sh --interactive

# Cleanup
./scenarios/severity-misdirection/cleanup.sh
```
