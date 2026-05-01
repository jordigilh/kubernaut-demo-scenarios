# Scenario: Security Context Constraint (SCC) Violation

**Status**: IN PROGRESS — manifests, run/validate/cleanup scripts, OCP overlay, and `fix-security-context-v1` RemediationWorkflow are implemented. Apply the workflow manifest to the cluster and run `./run.sh` on OpenShift to validate end-to-end.

## Overview

Demonstrates Kubernaut remediating a Deployment that cannot roll out new pods because an updated monitoring agent spec requests `NET_ADMIN` and `runAsUser: 0`, which the namespace ServiceAccount cannot satisfy under the default `restricted-v2` SCC. The observable signal is zero available replicas with ReplicaSet `FailedCreate` events referencing SCC validation.

## ITIL Mapping

| Level | Task |
|-------|------|
| L2 | Security remediation — SCC policy compliance after a deployment update |

## Signal

| Field | Value |
|-------|-------|
| Alert | `SCCViolationPodBlocked` (kube-state-metrics: desired replicas > 0, available == 0) |
| Source | Prometheus / Alertmanager |
| Severity | high |

## Flow

1. Deploy a compliant `metrics-agent` (`busybox`) in namespace `demo-scc`.
2. `inject-privileged-requirement.sh` patches the Deployment to require root + `NET_ADMIN`.
3. New pods fail SCC admission; Prometheus fires `SCCViolationPodBlocked` after 60s `for` duration.
4. Remediation selects **FixSecurityContext** (`fix-security-context-v1`) based on enriched workflow metadata (ReplicaSet event patterns, SCC denial wording).
5. Validation asserts pipeline completion, workflow bundle `fix-security-context-job`, at least one Running pod, and `runAsUser` is no longer `0`.

## Prerequisites

- OpenShift (or compatible cluster) with SCC enforcement and kube-state-metrics scraped by Prometheus
- Kubernaut platform and remediation workflows installed; workflow: `deploy/remediation-workflows/scc-violation/scc-violation.yaml`

## Usage

```bash
./scenarios/scc-violation/run.sh [--auto-approve|--interactive] [--no-validate]
./scenarios/scc-violation/validate.sh [--auto-approve]
./scenarios/scc-violation/cleanup.sh
```

On OpenShift, manifests are applied from `overlays/ocp` (cluster-monitoring label on the namespace; `release` label removed from `PrometheusRule`).

## Investigation Hints

- `kubectl get events -n demo-scc --field-selector reason=FailedCreate`
- Compare pod `securityContext` to namespace default SCC / ServiceAccount bindings
- Alert annotations point at SCC-style denials as the common cause for this signal pattern
