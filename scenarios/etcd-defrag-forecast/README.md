# Scenario: etcd Defrag Forecast -- Predictive Defragmentation

> **Environment: OCP only.** Demonstrates Kubernaut's reasoning capabilities
> for etcd maintenance -- a use case where intelligent triage outperforms
> the operator's fixed-policy automation.

## Overview

A standalone 3-member etcd cluster is deployed in a demo namespace. Fragmentation
is injected by writing and deleting thousands of keys. The `EtcdHighFragmentationRatio`
alert fires, triggering the Kubernaut pipeline.

The LLM investigates etcd health (member status, leader election, fragmentation
ratio, database growth trends) and decides whether defrag is safe. If all members
are healthy and fragmentation is the issue (not an active key leak), it selects
the `DefragEtcd` workflow. Manual approval is required before execution.

The workflow performs a rolling defrag: one member at a time, with health checks
between each, to ensure cluster availability is maintained.

## Why Kubernaut vs. the Operator

The `cluster-etcd-operator` runs defrag on a fixed threshold/schedule. Kubernaut adds:

- **Investigation**: Checks member health, quorum stability, and distinguishes
  fragmentation from active growth (object leak) before acting
- **Safety gating**: LLM refuses to defrag if members are unhealthy or quorum is at risk
- **Root cause analysis**: Identifies whether defrag is the right action or if the
  real issue is upstream (e.g., runaway controller creating objects)
- **Audit trail**: Full RR -> SP -> AA -> WFE pipeline with captured reasoning
- **Approval gate**: Manual approval for control-plane operations

## ITIL Classification

| Field | Value |
|-------|-------|
| **ITIL Level** | L2 -- Availability Management |
| **Category** | Predictive / Infrastructure |
| **Signal** | `EtcdHighFragmentationRatio` |
| **ActionType** | `DefragEtcd` (new) |
| **Workflow** | `defrag-etcd-v1` (new) |
| **Approval** | Manual (production + critical component) |
| **Status** | IN PROGRESS |

## Architecture

```
StatefulSet: etcd (3 replicas, no TLS)
  etcd-0, etcd-1, etcd-2
  Peer discovery: etcd-headless Service (DNS SRV)
  Client access: etcd-client Service (port 2379)
  Metrics: /metrics on port 2381

ServiceMonitor -> Prometheus scrapes etcd metrics

inject-fragmentation.sh:
  kubectl exec etcd-0 -> write 50k keys -> delete all
  -> db_total >> db_in_use -> fragmentation > 50%

EtcdHighFragmentationRatio alert fires
  -> RR -> SP -> AA (LLM investigates) -> Manual Approval -> WFE
  -> remediate.sh: rolling defrag via kubectl exec
  -> fragmentation drops < 30%
```

## Signal

```promql
(
  etcd_mvcc_db_total_size_in_bytes{namespace="demo-datastore"}
  - etcd_mvcc_db_total_size_in_use_in_bytes{namespace="demo-datastore"}
)
/ etcd_mvcc_db_total_size_in_bytes{namespace="demo-datastore"}
> 0.5
```

Fires when >50% of the etcd database is fragmented space. The alert description
is purely factual -- no diagnostic guidance for the LLM.

## Validation

| Assertion | Expected |
|-----------|----------|
| RR phase | Completed |
| RR outcome | Remediated |
| AA selected workflow | `defrag-etcd-v1` |
| Manual approval required | `true` |
| RCA mentions fragmentation | Yes |
| RCA target | StatefulSet/etcd |
| WFE phase | Completed |
| Post-defrag fragmentation | < 30% on at least one member |

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | OCP with Kubernaut services deployed |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | With ServiceMonitor support for user namespaces |
| Workflow catalog | `defrag-etcd-v1` registered in DataStorage |
| Images | `quay.io/coreos/etcd:v3.4.27` |
| Storage | StorageClass for 3x 1Gi PVCs (etcd data) |

### Workflow RBAC

The `defrag-etcd-v1-runner` ServiceAccount needs:

```yaml
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]
- apiGroups: ["apps"]
  resources: ["statefulsets"]
  verbs: ["get", "list"]
```

### Pre-flight checklist

```bash
# 1. Verify the defrag workflow is registered
kubectl get remediationworkflow -n kubernaut-system | grep defrag-etcd

# 2. Verify etcd image is pullable
skopeo inspect docker://quay.io/coreos/etcd:v3.4.27 | grep Architecture

# 3. Verify StorageClass is available for PVCs
kubectl get sc -o name | head -3

# 4. Verify Prometheus can scrape user-namespace ServiceMonitors
kubectl get servicemonitor --all-namespaces | grep -v openshift | head -5
```

## Migration to Real Cluster etcd

Once validated with standalone etcd, migrating to the real cluster etcd requires:

1. Change PrometheusRule namespace filter to `openshift-etcd`
2. Update RBAC to target `openshift-etcd` for `pods/exec`
3. Update `remediate.sh` pod label selector to match `openshift-etcd` pod labels
4. Add TLS flags to `etcdctl` commands (certs are inside the etcd pods)
5. No architectural changes -- same pipeline, different target namespace

## Usage

```bash
# Run with auto-approval (overrides manual gate for testing)
./scenarios/etcd-defrag-forecast/run.sh --auto-approve

# Run with manual approval gate (production behavior)
./scenarios/etcd-defrag-forecast/run.sh --interactive

# Cleanup
./scenarios/etcd-defrag-forecast/cleanup.sh
```
