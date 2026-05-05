# Scenario: Cross-Namespace Dependency Tracing

> **Environment: OCP only.** Tests the LLM's ability to trace root cause analysis
> across Kubernetes namespace boundaries.

## Overview

Shared infrastructure (PostgreSQL) lives in `demo-xns-infra` while application
workloads (api-gateway, payment-processor) live in `demo-xns-app`. The apps connect
to PostgreSQL via the cross-namespace DNS name `postgres.demo-xns-infra.svc`.

When PostgreSQL crashes, both apps lose connectivity and start crash-looping. The
alert fires in `demo-xns-app`, but the root cause is `Deployment/postgres` in
`demo-xns-infra`. The LLM must follow the cross-namespace breadcrumb trail in the
application logs to identify the correct remediation target in a different namespace.

This is the first scenario to validate **cross-namespace `remediationTarget` resolution**
where the RCA target lives in a different namespace than the alert source.

## ITIL Classification

| Field | Value |
|-------|-------|
| **ITIL Level** | L3 -- Advanced Diagnostics |
| **Category** | Reactive / Cross-Namespace Tracing |
| **Signal** | `KubePodCrashLooping` (apps in `demo-xns-app`) |
| **ActionType** | `RollbackDeployment` (existing) |
| **Workflow** | `rollback-deployment-v1` or `crashloop-rollback-v1` (existing) |

## Architecture

```
demo-xns-infra                    demo-xns-app
  postgres (shared DB)              api-gateway          payment-processor
       |                               |                        |
  [fault injected]            connects cross-ns          connects cross-ns
  crash-loops              postgres.demo-xns-infra.svc  postgres.demo-xns-infra.svc
       |                               |                        |
       |                         loses PG conn              loses PG conn
       |                         crash-loops                crash-loops
       |                               |                        |
       |                     KubePodCrashLooping      KubePodCrashLooping
       |                          Alert #1                 Alert #2
       |                               |                        |
       |                         RR (demo-xns-app)              |
       |                               |                        |
       |                        AI Analysis                     |
       |                     reads app logs:                    |
       |                     "Cannot connect to                 |
       |                      postgres.demo-xns-infra.svc"     |
       |                               |                        |
       |                     remediationTarget:                 |
       |                     demo-xns-infra/Deployment/postgres |
       |                               |                        |
       |<-------- rollback -----------|                        |
  PG recovers                                                  |
       |                                                       |
  apps auto-recover                                           |
```

## Cross-Namespace Tracing Mechanism

The LLM must:

1. Investigate the crash-looping pod in `demo-xns-app`
2. Read application logs showing `FATAL: Cannot connect to postgres.demo-xns-infra.svc:5432`
3. Recognize the FQDN as a cross-namespace Kubernetes service reference
4. Investigate `Deployment/postgres` in `demo-xns-infra` (using cluster-wide RBAC)
5. Identify the faulty postgres as the root cause
6. Set `remediationTarget` to `Deployment/postgres` in namespace `demo-xns-infra`

The RO's lock key includes namespace (`demo-xns-infra/Deployment/postgres`),
so the lock and WFE correctly target the infrastructure namespace.

## Fault Injection

`inject-failure.sh` patches the postgres Deployment in `demo-xns-infra` with:
```
command: ["sh", "-c", "echo INJECTED FAULT: postgres forced crash; exit 1"]
```

The rollback workflow reverts this to the previous healthy revision.

## Validation

| Assertion | Expected |
|-----------|----------|
| RR phase | Completed |
| RR outcome | Remediated / Inconclusive / Escalated |
| AA RCA target name | `postgres` |
| AA RCA target namespace | `demo-xns-infra` (cross-namespace) |
| AA RCA target kind | `Deployment` |
| WFE phase | Completed (when Remediated) |
| postgres pod | Running in `demo-xns-infra` after remediation |

### Multi-Path Outcomes

| Path | RCA Target | Namespace | Grade |
|------|------------|-----------|-------|
| A (ideal) | `Deployment/postgres` | `demo-xns-infra` | Pass |
| B (partial) | `Deployment/postgres` | missing or `demo-xns-app` | Pass with warning |
| C (acceptable) | Other target | any | Pass with warning |
| D (acceptable) | N/A (escalated) | N/A | Pass |

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

# 2. Verify Kubernaut Agent has cluster-wide read RBAC
kubectl auth can-i list pods --as=system:serviceaccount:kubernaut-system:kubernaut-agent \
  -n demo-xns-infra

# 3. Verify kube-state-metrics is scraping restart counts
kubectl exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=kube_pod_container_status_restarts_total' \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'{len(r[\"data\"][\"result\"])} pods reporting')"
```

## Usage

```bash
# Run with auto-approval
./scenarios/cross-namespace-dependency/run.sh --auto-approve

# Run with manual approval gate
./scenarios/cross-namespace-dependency/run.sh --interactive

# Cleanup
./scenarios/cross-namespace-dependency/cleanup.sh
```
