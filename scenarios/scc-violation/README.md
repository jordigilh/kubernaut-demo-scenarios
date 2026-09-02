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

1. Deploy a compliant `metrics-agent` (`busybox`) in namespace `demo-agents`.
2. `inject-privileged-requirement.sh` patches the Deployment to require root + `NET_ADMIN`.
3. New pods fail SCC admission; Prometheus fires `SCCViolationPodBlocked` after 60s `for` duration.
4. Remediation selects **FixSecurityContext** (`fix-security-context-v1`) based on enriched workflow metadata (ReplicaSet event patterns, SCC denial wording).
5. Validation asserts pipeline completion, workflow bundle `fix-security-context-job`, at least one Running pod, and `runAsUser` is no longer `0`.

## Prerequisites

- OpenShift (or compatible cluster) with SCC enforcement and kube-state-metrics scraped by Prometheus
- Kubernaut platform and remediation workflows installed; workflow: `deploy/remediation-workflows/scc-violation/scc-violation.yaml`

## Usage

```bash
./scenarios/scc-violation/run.sh [--auto-approve|--interactive] [--no-validate] [--alert-only]
./scenarios/scc-violation/validate.sh [--auto-approve]
./scenarios/scc-violation/cleanup.sh
```

### `run.sh` flags

| Flag | Behavior | When to use |
|------|----------|-------------|
| *(no flag)* | Runs the full pipeline with auto-approval (default) | Automated regression testing |
| `--no-validate` | Injects fault only, skips pipeline polling | **Always use with kagenti** |
| `--interactive` | Runs the pipeline, pauses at AwaitingApproval for manual approval | Gateway flow with human-in-the-loop |
| `--auto-approve` | Runs the full pipeline, auto-approves remediation | Automated regression testing (explicit) |
| `--alert-only` | Deploys, injects fault, waits for alert to fire, then exits | AF/A2A demos |

On OpenShift, manifests are applied from `overlays/ocp` (cluster-monitoring label on the namespace; `release` label removed from `PrometheusRule`).

## Fleet Mode

Runs the workload on a separate **spoke** cluster while the Kubernaut control plane runs
on a **hub** cluster. Requires the `--fleet` flag plus both kubeconfig env vars (passing
`--fleet` without either is a hard error):

```bash
export HUB_KUBECONFIG=~/.kube/kubernaut-hub-config       # e.g. from `make setup-fleet-demo-infra`
export SPOKE_KUBECONFIG=~/.kube/kubernaut-remote-cluster-config

./scenarios/scc-violation/run.sh --fleet                # full pipeline, auto-approve (default)
./scenarios/scc-violation/run.sh --fleet --interactive  # full pipeline, manual RAR approval
./scenarios/scc-violation/run.sh --fleet --alert-only    # stop once the alert reaches the hub
```

Deploys and faults the workload on the spoke, confirms the `SCCViolationPodBlocked` alert
reaches the hub's Alertmanager, then (unless `--alert-only`) drives the same
`wait_for_rr`/`poll_pipeline` loop single-cluster mode uses -- just pointed at the hub's
`kubernaut-system` namespace instead of the ambient cluster.

## Investigation Hints

- `kubectl get events -n demo-agents --field-selector reason=FailedCreate`
- Compare pod `securityContext` to namespace default SCC / ServiceAccount bindings
- Alert annotations point at SCC-style denials as the common cause for this signal pattern
