# Operator OOMKill: Informer Cache Flooding

## Overview

Demonstrates Kubernaut remediating a **real-world operator vulnerability**: an unfiltered
`controller-runtime` informer cache that allows any user with the standard `edit` ClusterRole
to OOMKill the operator by flooding ConfigMaps.

This scenario reproduces the vulnerability documented in
[kubeflow/spark-operator#2878](https://github.com/kubeflow/spark-operator/pull/2878) and the
Red Hat Developer blog post
[Protect your Kubernetes Operator from OOMKill](https://developers.redhat.com/articles/2026/06/01/protect-your-kubernetes-operator-oomkill).

**OCP-only scenario.**

| | |
|---|---|
| **Signal** | `KubePodCrashLooping` -- operator pod OOMKilled by informer cache overflow |
| **Root cause** | Unfiltered `ByObject` ConfigMap cache in `controller-runtime` (CVE: kubeflow/spark-operator#2878) |
| **Attack vector** | 100 ConfigMaps at ~1MB each (~100MB raw, 300-500MB after Go struct deserialization overhead, exceeds 512Mi limit) |
| **Remediation** | `IncreaseMemoryLimits` -- doubles memory limit as emergency triage |

## The Vulnerability

In `controller-runtime` operators, the informer cache is configured via `ByObject`:

```go
ByObject: map[client.Object]cache.ByObject{
    &corev1.Pod{}: {
        Label: labels.SelectorFromSet(labels.Set{
            "app.kubernetes.io/managed-by": "demo-operator",
        }),
    },
    &corev1.ConfigMap{}: {},  // <-- caches ALL ConfigMaps (no label filter)
}
```

The Pod informer is correctly filtered by label. The ConfigMap informer has **no filter** --
it caches every ConfigMap in scope. The empty `{}` configuration directs the informer to
perform a full `LIST` and persistent `WATCH` on all ConfigMaps, deserializing each into a
typed Go struct (`corev1.ConfigMap`) with map headers, string headers, and pointer indirection.

An attacker creates 100 ConfigMaps at ~1MB each (the Kubernetes maximum). The informer caches
~100MB of raw data, but Go struct deserialization adds 3-5x overhead (map headers, string
headers, pointer indirection), pushing the in-memory footprint to 300-500MB. This exceeds the
512Mi memory limit. The operator OOMKills, restarts, attempts to re-list everything, and
crashes again -- entering CrashLoopBackOff.

## Signal Flow

```
inject-configmap-flood.sh creates 100 x 1MB ConfigMaps
  -> operator informer caches all into Go structs (~100MB raw, 300-500MB with overhead)
  -> exceeds 512Mi memory limit -> OOMKill -> CrashLoopBackOff
  -> KubePodCrashLooping alert fires (1m for clause)
  -> Kubernaut pipeline:
     SP: enriches signal (severity=critical, env=production)
     AA: KA investigates OOMKill
       -> kubectl describe: lastState.terminated.reason=OOMKilled
       -> kubectl top: memory at limit before crash
       -> identifies operator memory exhaustion from ConfigMap volume
     -> Selects IncreaseMemoryLimits workflow (confidence ~0.85)
     WFE: patches memory limit 512Mi -> 1Gi
     EM: verifies operator is running (healthScore=1)
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | OCP with Kubernaut services deployed |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | With kube-state-metrics scraping |
| Workflow catalog | `increase-memory-limits-v1` registered in DataStorage |

## Running the Scenario

```bash
export PLATFORM=ocp
./scenarios/operator-oomkill-informer/run.sh
```

Options:
- `--interactive` -- pause at approval step for manual approval
- `--no-validate` -- skip the validation pipeline (deploy + inject only)

## Cleanup

```bash
./scenarios/operator-oomkill-informer/cleanup.sh
```

## Expected LLM Reasoning

| Field | Expected Value |
|-------|---------------|
| **Root Cause** | Operator pod OOMKilled -- memory usage exceeded 512Mi limit due to large number of ConfigMaps in the namespace being cached by the informer |
| **Severity** | critical |
| **Target Resource** | Deployment/demo-controllers-controller (ns: demo-controllers) |
| **Workflow Selected** | increase-memory-limits-v1 |
| **Confidence** | ~0.85 (increasing limits is emergency triage; the real fix is adding label selectors to the informer cache) |
| **Approval** | Required (production environment, critical severity) |

## Acceptance Criteria

- [ ] Operator OOMKills after ConfigMap flood injection
- [ ] `KubePodCrashLooping` alert fires in AlertManager
- [ ] LLM correctly identifies OOMKill as the termination reason
- [ ] LLM identifies ConfigMap volume in the namespace as a contributing factor
- [ ] `IncreaseMemoryLimits` workflow is selected
- [ ] Confidence >= 0.7
- [ ] Memory limit is patched from 512Mi to a higher value
- [ ] Operator stabilizes after limit increase (EM healthScore=1)

## BDD Specification

```gherkin
Feature: Operator OOMKill remediation from informer cache flooding

  Scenario: Unfiltered ConfigMap informer causes operator OOMKill
    Given a controller-runtime operator "demo-controllers-controller" in namespace "demo-controllers"
      And the operator has an unfiltered ConfigMap informer cache
      And the operator has a 512Mi memory limit

    When 100 ConfigMaps at ~1MB each are created in the namespace
      And the informer deserializes all ConfigMaps into Go structs (3-5x overhead)
      And the in-memory cache exceeds 512Mi
      And the operator is OOMKilled and enters CrashLoopBackOff
      And the KubePodCrashLooping alert fires

    Then Kubernaut detects the crash loop via AlertManager
      And Signal Processing enriches with severity=critical
      And KA diagnoses OOMKill from memory limit exhaustion
      And the LLM selects IncreaseMemoryLimits workflow
      And WorkflowExecution patches the memory limit
      And the operator recovers and stabilizes
      And Effectiveness Monitor confirms healthScore=1
```

## References

- [Protect your Kubernetes Operator from OOMKill](https://developers.redhat.com/articles/2026/06/01/protect-your-kubernetes-operator-oomkill) -- Red Hat Developer blog post
- [kubeflow/spark-operator#2878](https://github.com/kubeflow/spark-operator/pull/2878) -- upstream fix
- [controller-runtime Cache Options](https://pkg.go.dev/sigs.k8s.io/controller-runtime/pkg/cache) -- official documentation
