# Scenario #122: Pending Pods -- Node Taint Removal

## Overview

A worker node has a `maintenance=scheduled:NoSchedule` taint that blocks pod scheduling.
Pods targeting that node via `nodeSelector` remain stuck in Pending. Kubernaut's LLM
investigates, identifies the taint as the root cause, and removes it.

**Signal**: `KubePodNotScheduled` -- pods Pending for >3 min
**Root cause**: Node taint blocking scheduling
**Remediation**: `kubectl taint nodes <node> maintenance-`

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Kind cluster | Multi-node with `kubernaut.ai/demo-taint-target=true` label on one worker |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics |
| Workflow catalog | `remove-taint-v1` registered in DataStorage |

## Automated Run

```bash
./scenarios/pending-taint/run.sh
```

## Platform Notes

### OCP

The `run.sh` script auto-detects the platform and applies the `overlays/ocp/` kustomization via `get_manifest_dir()`. The overlay:

- Adds `openshift.io/cluster-monitoring: "true"` to the demo namespace
- Swaps `nginx:1.27-alpine` to `nginxinc/nginx-unprivileged:1.27-alpine` (port 80 → 8080, probes adjusted)
- Removes the `release` label from `PrometheusRule`

No manual steps required.

## Cleanup

```bash
./scenarios/pending-taint/cleanup.sh
```

## BDD Specification

```gherkin
Given a Kind cluster with a worker node labeled kubernaut.ai/demo-taint-target=true
  And the worker node has a maintenance=scheduled:NoSchedule taint
  And the "remove-taint-v1" workflow is registered in DataStorage

When the batch-processor deployment is created with nodeSelector for the worker node
  And pods remain in Pending state because the taint blocks scheduling
  And the KubePodNotScheduled alert fires after 3 minutes

Then the LLM investigates the Pending pods and identifies the node taint
  And selects the RemoveTaint workflow
  And WE removes the maintenance taint from the worker node
  And the Pending pods get scheduled and reach Running state
  And EM confirms all pods are healthy
```

## Acceptance Criteria

- [ ] Worker node has NoSchedule taint applied
- [ ] Pods remain in Pending state
- [ ] Alert fires after 3 minutes
- [ ] LLM identifies the taint as root cause (not resource shortage)
- [ ] RemoveTaint workflow is selected
- [ ] Taint is removed from the node
- [ ] Pods transition from Pending to Running
- [ ] EM confirms healthy state
