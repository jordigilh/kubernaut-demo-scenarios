# Scenario: RBAC Failure (RoleBinding loss)

**Status**: IN PROGRESS — scenario scripts and manifests implemented; end-to-end validation pending on live cluster.

## Overview

Demonstrates Kubernaut diagnosing and remediating loss of namespace RBAC after a
RoleBinding is deleted (for example during a security audit cleanup). The
`metrics-collector` workload uses a ServiceAccount that lists pods; without the
RoleBinding it receives 403 Forbidden from the API server, the readiness probe
fails, and the Deployment reports zero available replicas.

## ITIL Mapping

| Level | Task |
|-------|------|
| L2 | Security / Access Management — RBAC policy compliance |

## Signal

| Field | Value |
|-------|-------|
| Alert | `RBACPolicyDenied` |
| Source | Prometheus (`kube_deployment_status_replicas_available` from kube-state-metrics) |
| Severity | high |

## Running

Requires a cluster with Prometheus Operator / user-workload monitoring and
kube-state-metrics scraping Deployment metrics.

```bash
./scenarios/rbac-failure/run.sh [--auto-approve|--interactive] [--no-validate]
./scenarios/rbac-failure/validate.sh [--auto-approve]
./scenarios/rbac-failure/cleanup.sh
```

## Remediation

Register `deploy/remediation-workflows/rbac-failure/rbac-failure.yaml` and the
`restore-rolebinding-job` workflow bundle. Expected action: `RestoreRoleBinding`.

## Prerequisites

- Kubernetes or OpenShift with PrometheusRule CRD and monitoring stack
- kube-state-metrics exposing deployment replica metrics
- Customer-defined remediation workflow registered in DataStorage
