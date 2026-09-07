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
| RR count | >= 2 for demo-fulfillment |
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

### `run.sh` flags

| Flag | Behavior | When to use |
|------|----------|-------------|
| *(no flag)* | Runs the full pipeline with auto-approval (default) | Automated regression testing |
| `--no-validate` | Injects fault only, skips pipeline polling | **Always use with kagenti** |
| `--interactive` | Runs the pipeline, pauses at AwaitingApproval for manual approval | Gateway flow with human-in-the-loop |
| `--auto-approve` | Runs the full pipeline, auto-approves remediation | Automated regression testing (explicit) |
| `--alert-only` | Deploys, injects fault, waits for alert to fire, then exits | AF/A2A demos |

### Fleet Mode

Runs the workload on a separate **spoke** cluster while the Kubernaut control plane runs
on a **hub** cluster. Requires the `--fleet` flag plus both kubeconfig env vars (passing
`--fleet` without either is a hard error):

```bash
export HUB_KUBECONFIG=~/.kube/kubernaut-hub-config       # e.g. from `make setup-fleet-demo-infra`
export SPOKE_KUBECONFIG=~/.kube/kubernaut-remote-cluster-config

./scenarios/cascading-service-failure/run.sh --fleet                # full pipeline, auto-approve (default)
./scenarios/cascading-service-failure/run.sh --fleet --interactive  # full pipeline, manual RAR approval
./scenarios/cascading-service-failure/run.sh --fleet --alert-only    # stop once the alert reaches the hub
```

Deploys and faults the workload on the spoke, confirms the `KubePodCrashLooping` alert
reaches the hub's Alertmanager, then (unless `--alert-only`) drives the same
`wait_for_rr`/`poll_pipeline` loop single-cluster mode uses -- just pointed at the hub's
`kubernaut-system` namespace instead of the ambient cluster.
