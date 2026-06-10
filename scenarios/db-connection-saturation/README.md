# Scenario: Database Connection Saturation -- Deep Investigation

> **Environment: OCP only.** Requires `postgres_exporter` sidecar for connection metrics
> and Prometheus scraping via ServiceMonitor.

## Overview

Tests LLM diagnostic depth: tracing from an application-level symptom (database connection
pool exhaustion) to an infrastructure root cause (a specific misbehaving workload leaking
connections). The LLM must investigate which workload is accumulating connections and
restart it -- not the database itself.

## ITIL Classification

| Field | Value |
|-------|-------|
| **ITIL Level** | L3 -- Performance Management |
| **Category** | Reactive / Deep Investigation |
| **Signal** | `DatabaseConnectionPoolExhausted` (pg_stat_activity_count) |
| **ActionType** | `GracefulRestart` (existing) |
| **Workflow** | `graceful-restart-v1` (existing) |
| **Status** | IN PROGRESS |

## Architecture

```
client-pool            postgres (max_connections=15)        Kubernaut
  (opens 1 conn/8s,           postgres_exporter sidecar           (deep investigation)
   never releases)              (pg_stat_activity_count)
       |                              |                               |
       v                              v                               v
  connections accumulate  -->  active > 10 threshold  -->  DatabaseConnectionPoolExhausted
                                                            --> RemediationRequest
  order-service: "FATAL:                                    --> AI Analysis (investigate WHO)
    too many connections"                                   --> Identify client-pool
  report-generator: same                                    --> GracefulRestart on client-pool
                                                            --> Connections released
                                                            --> EffectivenessAssessment
```

## Signal

The `DatabaseConnectionPoolExhausted` alert fires when active connections exceed the
warning threshold (10 out of 15 `max_connections`):

```promql
pg_stat_activity_count{
  namespace="demo-orders",
  datname="demo",
  state="active"
} > 10
```

## Workload

- **Deployment `postgres`**: PostgreSQL 16 with `max_connections=15`,
  `superuser_reserved_connections=3`. Includes `postgres_exporter` sidecar for metrics.
- **Deployment `client-pool`**: Opens persistent `psql` sessions (~1 every 8s)
  that hold connections indefinitely via `SELECT pg_sleep(86400)`. Logs clearly identify
  each leaked connection: `[client-pool] Opening persistent connection #N`.
- **Deployment `order-service`**: Normal workload using short-lived connections. Logs
  `[order-service] ERROR: Database query failed` when pool is exhausted.
- **Deployment `report-generator`**: Same pattern as order-service, different name.

## Investigation Expectations

The LLM should:

1. Query `pg_stat_activity_count` to see connection distribution
2. Read logs from all deployments in the namespace
3. Notice `client-pool` logs show accumulating persistent connections
4. Notice `order-service` and `report-generator` show connection errors (victims, not cause)
5. Identify `Deployment/client-pool` as the `remediationTarget`
6. Select `GracefulRestart` to restart the client-pool and release all held connections

## Validation (Multi-Path)

| Path | RCA Target | Outcome | Grade |
|------|------------|---------|-------|
| A (ideal) | `Deployment/client-pool` | Remediated | Pass |
| B (acceptable) | `Deployment/postgres` | Remediated | Pass (suboptimal) |
| C (acceptable) | Any other target | Remediated | Pass with warning |
| D (acceptable) | N/A (escalated) | Escalated | Pass |
| E (fail) | None | No action | Fail |

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | OCP with Kubernaut services deployed |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | Scraping via ServiceMonitor (user-workload-monitoring or platform Prometheus with `openshift.io/cluster-monitoring` label) |
| KA Prometheus | Auto-enabled by `run.sh`, reverted by `cleanup.sh` ([manual enablement](../../docs/prometheus-toolset.md)) |
| Workflow catalog | `graceful-restart-v1` registered in DataStorage (shared with memory-leak scenario) |
| Images | `postgres:16-alpine` (Kind) or `quay.io/sclorg/postgresql-16-c9s` (OCP), `quay.io/prometheuscommunity/postgres-exporter:latest` |

### Workflow RBAC

This scenario reuses the `graceful-restart-v1` workflow from the memory-leak scenario.
No additional RBAC is needed.

| Resource | Name |
|----------|------|
| ServiceAccount | `graceful-restart-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `graceful-restart-v1-runner` |
| ClusterRoleBinding | `graceful-restart-v1-runner` |

### Pre-flight checklist

```bash
# 1. Verify postgres_exporter image is available
kubectl run test-exporter --image=quay.io/prometheuscommunity/postgres-exporter:latest \
  --restart=Never --rm -it --command -- sh -c 'echo ok' 2>/dev/null && echo "Image available"

# 2. Verify the graceful-restart workflow is registered
kubectl get remediationworkflow graceful-restart-v1 -n kubernaut-system

# 3. Verify the workflow runner SA exists
kubectl get sa graceful-restart-v1-runner -n kubernaut-workflows
```

## Usage

```bash
# Run with auto-approval
./scenarios/db-connection-saturation/run.sh --auto-approve

# Run with manual approval gate
./scenarios/db-connection-saturation/run.sh --interactive

# Cleanup
./scenarios/db-connection-saturation/cleanup.sh
```
