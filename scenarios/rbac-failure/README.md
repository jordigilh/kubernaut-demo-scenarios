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
./scenarios/rbac-failure/run.sh [--auto-approve|--interactive] [--no-validate] [--alert-only]
./scenarios/rbac-failure/validate.sh [--auto-approve]
./scenarios/rbac-failure/cleanup.sh
```

### `run.sh` flags

| Flag | Behavior | When to use |
|------|----------|-------------|
| *(no flag)* | Runs the full pipeline with auto-approval (default) | Automated regression testing |
| `--no-validate` | Injects fault only, skips pipeline polling | **Always use with kagenti** |
| `--interactive` | Runs the pipeline, pauses at AwaitingApproval for manual approval | Gateway flow with human-in-the-loop |
| `--auto-approve` | Runs the full pipeline, auto-approves remediation | Automated regression testing (explicit) |
| `--alert-only` | Deploys, injects fault, waits for alert to fire, then exits | AF/A2A demos |

## Fleet Mode

Runs the workload on a separate **spoke** cluster while the Kubernaut control plane runs
on a **hub** cluster. Requires the `--fleet` flag plus both kubeconfig env vars (passing
`--fleet` without either is a hard error):

```bash
export HUB_KUBECONFIG=~/.kube/kubernaut-hub-config       # e.g. from `make setup-fleet-demo-infra`
export SPOKE_KUBECONFIG=~/.kube/kubernaut-remote-cluster-config

./scenarios/rbac-failure/run.sh --fleet                # full pipeline, auto-approve (default)
./scenarios/rbac-failure/run.sh --fleet --interactive  # full pipeline, manual RAR approval
./scenarios/rbac-failure/run.sh --fleet --alert-only    # stop once the alert reaches the hub
```

Deploys and faults the workload on the spoke, confirms the `RBACPolicyDenied` alert
reaches the hub's Alertmanager, then (unless `--alert-only`) drives the same
`wait_for_rr`/`poll_pipeline` loop single-cluster mode uses -- just pointed at the hub's
`kubernaut-system` namespace instead of the ambient cluster.

## Remediation

Register `deploy/remediation-workflows/rbac-failure/rbac-failure.yaml` and the
`restore-rolebinding-job` workflow bundle. Expected action: `RestoreRoleBinding`.

## Prerequisites

- Kubernetes or OpenShift with PrometheusRule CRD and monitoring stack
- kube-state-metrics exposing deployment replica metrics
- Customer-defined remediation workflow registered in DataStorage
