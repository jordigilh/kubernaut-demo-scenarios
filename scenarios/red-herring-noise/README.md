# Scenario: Red Herring / Multi-Incident Separation

> **Environment: OCP only.** Tests the LLM's ability to separate independent
> failures from a primary cascade when unrelated alerts fire simultaneously
> in the same namespace.

## Overview

A single namespace hosts the primary application stack (api-gateway, worker,
postgres) plus an unrelated canary deployment (canary-v2) that references a
nonexistent image. When PostgreSQL crashes, two dependent apps crash-loop.
Simultaneously, the canary generates an `ImagePullBackOff` alert.

Three or more alerts fire in the same namespace:
- 2x `KubePodCrashLooping` (api-gateway, worker) -- caused by postgres
- 1x `ImagePullBackOffPersistent` (canary-v2) -- completely unrelated

The LLM must recognize that the crash-loop alerts share a common root cause
(postgres) and that the `ImagePullBackOff` is an **independent incident** that
must not contaminate the RCA.

## ITIL Classification

| Field | Value |
|-------|-------|
| **ITIL Level** | L3 -- Advanced Diagnostics |
| **Category** | Reactive / Multi-Incident Separation |
| **Signal** | `KubePodCrashLooping` (x2) + `ImagePullBackOffPersistent` (x1) |
| **ActionType** | `PatchConfiguration` (existing) |
| **Workflow** | `hotfix-config-v1` (existing) |

## Architecture

```
postgres (shared DB)     api-gateway     worker        canary-v2 (RED HERRING)
     |                      |              |                |
[fault injected]       depends on PG   depends on PG   bad image tag
crash-loops               |              |           ImagePullBackOff
     |                loses PG conn   loses PG conn       |
     |                crash-loops     crash-loops          |
     |                     |              |                |
     |           KubePodCrashLooping  KubePodCrashLooping  ImagePullBackOffPersistent
     |              Alert #1           Alert #2            Alert #3 (UNRELATED)
     |                     |              |                |
     |                 RR #1          RR #2             RR #3
     |                     |              |                |
     |              AI Analysis      AI Analysis      AI Analysis
     |                     |              |                |
     |             remediationTarget:   ResourceBusy   independent
     |             Deployment/postgres  (blocked)      diagnosis
     |                     |
     |<---- patch CM ------|
  PG recovers
     |
  apps auto-recover
```

## Multi-Incident Separation Challenge

The challenge has two dimensions:

1. **Noise filtering**: The canary-v2 `ImagePullBackOff` alert fires alongside
   the crash-loop alerts. A naive LLM might try to correlate all three alerts
   and produce a confused RCA that mixes independent root causes.

2. **Cascade recognition**: The two crash-loop alerts share the same root cause
   (postgres). The LLM must recognize this cascade pattern and identify postgres
   as the shared dependency, not treat each crash-loop independently.

The LLM should:
- Read logs from all deployments in the namespace
- Observe that api-gateway and worker both show "Cannot connect to postgres"
- Observe that canary-v2 is stuck in ImagePullBackOff with no postgres dependency
- Conclude that postgres is the root cause for the crash-loops
- Recognize canary-v2 as a separate, unrelated incident

## Fault Injection

`inject-faults.sh` patches the `postgres-config` ConfigMap to add
`invalid_directive: true`, then restarts the postgres Deployment. The entrypoint
wrapper detects the invalid directive and exits immediately, crashing postgres.
This aligns with `hotfix-config-v1`'s PatchConfiguration remediation strategy.

The canary-v2 decoy is deployed from the start with a nonexistent image tag
(`registry.example.com/myorg/api-server:v2.0.0-rc1-does-not-exist`).

## Validation

| Assertion | Expected |
|-----------|----------|
| RR count | >= 2 |
| AA RCA target (crash-loop RR) | `Deployment/postgres` (not canary-v2) |
| Blocked RRs | >= 1 with `ResourceBusy` (dedup) |
| postgres pod | Running after remediation |

### Multi-Path Outcomes

| Path | RCA Target | Grade |
|------|------------|-------|
| A (ideal) | `Deployment/postgres` with dedup | Pass |
| B (polluted) | `Deployment/canary-v2` | Fail (red herring polluted RCA) |
| C (acceptable) | Other valid target | Pass with warning |
| D (acceptable) | Escalated | Pass |

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | OCP with Kubernaut services deployed |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | With kube-state-metrics for restart counts and waiting reasons |
| Workflow catalog | `rollback-deployment-v1` or `crashloop-rollback-v1` registered |
| Images | `quay.io/sclorg/postgresql-16-c9s` (OCP) |

### Workflow RBAC

This scenario reuses existing deployment rollback workflows. No additional RBAC needed.

### Pre-flight checklist

```bash
# 1. Verify the rollback workflow is registered
kubectl get remediationworkflow -n kubernaut-system | grep -E 'rollback|crashloop'

# 2. Verify kube-state-metrics reports waiting reasons
kubectl exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=kube_pod_container_status_waiting_reason' \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'{len(r[\"data\"][\"result\"])} series')"
```

## Usage

```bash
# Run with auto-approval
./scenarios/red-herring-noise/run.sh --auto-approve

# Run with manual approval gate
./scenarios/red-herring-noise/run.sh --interactive

# Cleanup
./scenarios/red-herring-noise/cleanup.sh
```
