# Scenario: Cascading Service Failure -- RO Target-Based Dedup

> **Environment: OCP only.** Tests the Remediation Orchestrator's deduplication
> mechanism when two independent RemediationRequests converge on the same root cause.

## Overview

PostgreSQL is the shared dependency for two microservices (order-processor,
inventory-sync). When PG crashes, both apps crash-loop, generating two independent
`KubePodCrashLooping` alerts and two separate RemediationRequests with different
signal fingerprints.

The LLM investigates each RR independently and should identify `Deployment/postgres`
as the `remediationTarget` for both. The RO's `AcquireLock` + `CheckResourceBusy`
mechanism then ensures only one WorkflowExecution runs against postgres; the second
RR is blocked with `ResourceBusy`.

This is the first scenario to validate the **post-AI-analysis dedup path** where
two RRs with different signals converge on the same RCA target.

## ITIL Classification

| Field | Value |
|-------|-------|
| **ITIL Level** | L3 -- Problem Management |
| **Category** | Reactive / RO Target Dedup |
| **Signal** | `KubePodCrashLooping` (x2, different pods) |
| **ActionType** | `RollbackDeployment` (existing) |
| **Workflow** | `rollback-deployment-v1` or `crashloop-rollback-v1` (existing) |
| **Status** | IN PROGRESS |

## Architecture

```
postgres (shared dependency)       order-processor         inventory-sync
         |                              |                        |
    [fault injected]                    |                        |
    crash-loops                    loses PG conn            loses PG conn
         |                         crash-loops              crash-loops
         |                              |                        |
         |                    KubePodCrashLooping      KubePodCrashLooping
         |                         Alert #1                 Alert #2
         |                              |                        |
         |                          RR #1                    RR #2
         |                              |                        |
         |                      AI Analysis #1           AI Analysis #2
         |                              |                        |
         |                    remediationTarget:       remediationTarget:
         |                    Deployment/postgres      Deployment/postgres
         |                              |                        |
         |                       AcquireLock OK          AcquireLock: spin
         |                       WFE created             CheckResourceBusy
         |                              |                -> Blocked (ResourceBusy)
         |<-------- rollback -----------|
    PG recovers                         |
         |                              |
    apps auto-recover              one WFE ran
```

## RO Dedup Mechanism

The dedup lifecycle is two-phase:

1. **Lock phase** (K8s Lease, 30s TTL): prevents two RRs from creating WFEs
   simultaneously. The loser spins on 5s requeue in `Analyzing` phase.
2. **WFE phase**: once the first WFE exists, `CheckResourceBusy` /
   `FindActiveWFEForTarget` blocks the second RR with `ResourceBusy` regardless
   of lock state. The WFE's `spec.targetResource` is keyed by
   `namespace/Kind/name` from the AIAnalysis `remediationTarget`.

## Fault Injection

`inject-pg-failure.sh` patches the postgres Deployment with:
```
command: ["sh", "-c", "echo INJECTED FAULT: postgres forced crash; exit 1"]
```

The rollback workflow reverts this to the previous healthy revision.

## Validation

| Assertion | Expected |
|-----------|----------|
| RR count | >= 2 for demo-cascade |
| Completed RRs | >= 1 |
| Blocked RRs | >= 1 with reason `ResourceBusy` |
| AA RCA target name | `postgres` |
| AA RCA target kind | `Deployment` |
| WFE phase | Completed |
| WFE count | Exactly 1 (dedup prevented second) |
| postgres pod | Running after remediation |

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | OCP with Kubernaut services deployed |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | With kube-state-metrics for `kube_pod_container_status_restarts_total` |
| Workflow catalog | `rollback-deployment-v1` or `crashloop-rollback-v1` registered in DataStorage |
| Images | `quay.io/sclorg/postgresql-16-c9s` (OCP) |

### Workflow RBAC

This scenario reuses the existing deployment rollback workflow. No additional RBAC needed.

### Pre-flight checklist

```bash
# 1. Verify the rollback workflow is registered
kubectl get remediationworkflow -n kubernaut-system | grep -E 'rollback|crashloop'

# 2. Verify kube-state-metrics is scraping restart counts
kubectl exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=kube_pod_container_status_restarts_total' \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'{len(r[\"data\"][\"result\"])} pods reporting')"
```

## Usage

```bash
# Run with auto-approval
./scenarios/cascading-service-failure/run.sh --auto-approve

# Run with manual approval gate
./scenarios/cascading-service-failure/run.sh --interactive

# Cleanup
./scenarios/cascading-service-failure/cleanup.sh
```
