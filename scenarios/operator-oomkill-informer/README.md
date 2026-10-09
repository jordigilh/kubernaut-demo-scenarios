# Operator OOMKill: Informer Cache Flooding

## Overview

Demonstrates Kubernaut remediating a **real-world operator vulnerability**: an unfiltered
`controller-runtime` informer cache that allows any user with the standard `edit` ClusterRole
to OOMKill the operator by flooding ConfigMaps.

This scenario reproduces the vulnerability documented in
[kubeflow/spark-operator#2878](https://github.com/kubeflow/spark-operator/pull/2878) and the
Red Hat Developer blog post
[Protect your Kubernetes Operator from OOMKill](https://developers.redhat.com/articles/2026/06/01/protect-your-kubernetes-operator-oomkill).

Supports Kind and OpenShift clusters. Fleet mode runs the workload on the
configured spoke while the Kubernaut control plane remains on the hub.

| | |
|---|---|
| **Signal** | `KubePodCrashLooping` -- operator pod OOMKilled by informer cache overflow |
| **Root cause** | Unfiltered `ByObject` ConfigMap cache in `controller-runtime` (CVE: kubeflow/spark-operator#2878) |
| **Attack vector** | 300 ConfigMaps at ~1MB each (~300MB raw, approximately 900-1500MB after Go struct deserialization overhead, exceeds both 128Mi and 256Mi limits) |
| **Fleet remediation** | `increase-memory-limits-gitops-v1` -- opens a reviewed forward-change PR on the hub, adds a fixed 128Mi to the limit, and waits for a human merge; the first increase is intentionally ineffective |
| **Local remediation** | Generic `increase-memory-limits-v1` direct Job workflow (the local path has no Argo CD Application) |

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

An attacker creates 300 ConfigMaps at ~1MB each (the Kubernetes maximum per object). The informer
caches ~300MB of raw data, but Go struct deserialization adds 3-5x overhead (map headers, string
headers, pointer indirection), pushing the in-memory footprint to roughly 900-1500MB. This
exceeds both the initial 128Mi memory limit and the workflow's deliberately fixed 256Mi first
remediation target. The operator OOMKills, restarts, attempts to re-list everything, and crashes
again -- entering CrashLoopBackOff.

## Signal Flow

```
inject-configmap-flood.sh creates 300 x 1MB ConfigMaps
  -> operator informer caches all into Go structs (~300MB raw, roughly 900-1500MB with overhead)
  -> exceeds 128Mi memory limit -> OOMKill -> CrashLoopBackOff
  -> KubePodCrashLooping alert fires (1m for clause)
  -> Kubernaut pipeline:
     SP: enriches signal (severity=critical, env=production)
     AA: KA investigates OOMKill
       -> kubectl describe: lastState.terminated.reason=OOMKilled
       -> kubectl top: memory at limit before crash
       -> identifies operator memory exhaustion from ConfigMap volume
  -> selects increase-memory-limits-gitops-v1 (fleet; confidence varies)
       RAR: human authorizes the remediation
       WFE Job on hub: creates a forward branch + PR; it never patches the spoke
       human reviewer approves and merges the protected-main PR
       Argo CD applies the merged revision to the spoke
        EM: independently verifies operator health, alerts, metrics, and spec hash
        -> alert and health evidence show the +128Mi change was ineffective
    -> Gateway's post-completion same-alert cooldown is set to 0 for the rehearsal
       -> the still-firing alert creates a second RR without clearing or reinjecting the flood
    -> platform remediation history/routing escalates the second RR to ManualReviewRequired
       -> no second WFE, RAR, PR, or memory increase is created
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services deployed |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | With kube-state-metrics and kubelet/cAdvisor scraping |
| Metrics API | metrics-server (or a platform-provided equivalent), so `kubectl top` can report workload CPU and memory |
| Workflow catalog | `increase-memory-limits-gitops-v1` plus the generic `increase-memory-limits-v1` registered in DataStorage |

The demo operator exposes controller-runtime metrics on port `8080`; the scenario
deploys a Service and ServiceMonitor for that endpoint. Pod CPU and memory usage
come from kubelet/cAdvisor (Prometheus) and the Kubernetes Metrics API (`kubectl top`),
not from the operator's own `/metrics` endpoint. In fleet mode, metrics-server must
be available on the spoke where the workload runs. Fleet mode uses a deterministic
300-object flood rather than live-limit auto-sizing: the initial load must remain over
the 256Mi limit after the first fixed `+128Mi` remediation so Effectiveness Monitor can
record a genuine ineffective attempt.

## Running the Scenario

```bash
# Kind local path (direct workflow; platform is auto-detected)
./scenarios/operator-oomkill-informer/run.sh

# OpenShift
PLATFORM=ocp ./scenarios/operator-oomkill-informer/run.sh
```

### `run.sh` flags

| Flag | Behavior | When to use |
|------|----------|-------------|
| *(no flag)* | Runs the full local pipeline with auto-approval; fleet defaults to the interactive PR/RAR path | Local smoke test |
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

./scenarios/operator-oomkill-informer/run.sh --fleet --interactive  # full pipeline, manual RAR approval + PR merge
./scenarios/operator-oomkill-informer/run.sh --fleet --auto-approve # only when rehearsing non-presentation automation
./scenarios/operator-oomkill-informer/run.sh --fleet --alert-only    # stop once the alert reaches the hub
```

Fleet mode seeds a scenario-owned Gitea repository and protected `main` branch on the
hub, registers the spoke as an Argo CD destination, and creates the Application that
owns the operator namespace. It then injects the flood on the spoke and confirms the
`KubePodCrashLooping` alert reaches the hub. The workflow runs on the hub with the
repository credential; the spoke never receives that Secret. `--interactive` requires
both an explicit RAR approval and a separate human PR review/merge. The Job remains
Running until it observes the merge; it does not approve, merge, push `main`, or patch
the live Deployment. Validation waits for the merged Argo revision, independent
effectiveness assessment, retained stimulus evidence, and a second RR created from
the continuing alert. The human-handoff decision belongs to platform routing/history,
not to the workflow Job.

Fleet mode temporarily sets the Remediation Orchestrator's
`asyncPropagation.gitOpsSyncDelay` to `10s` and
`effectivenessAssessment.stabilizationWindow` to `5m`. The Gitea push webhook triggers
Argo CD reconciliation immediately, so a longer polling-oriented delay is unnecessary;
the full stabilization window gives the retained informer load time to expose a delayed
ineffective remediation while retaining independent health, alert, metrics, and spec-hash
assessment. Fleet mode also temporarily
sets Gateway's `processing.deduplication.cooldownPeriod` to `0s`, allowing a fresh delivery
for the still-firing alert after the first RR completes; `cleanup.sh` restores both the
Gateway and RO configurations. Set `GITOPS_SYNC_DELAY`,
`EFFECTIVENESS_STABILIZATION_WINDOW`, or `GATEWAY_DEDUP_COOLDOWN` only when the environment
needs different run-scoped values.

### Reviewing the GitOps PR

The workflow prints the exact link as `FORWARD_CHANGE_PR_URL`. With the default
repository name, the in-cluster URL is:

```text
http://gitea-http.gitea:3000/kubernaut/demo-operator-oomkill-repo/pulls/<PR_NUMBER>
```

To make Gitea reachable from a browser on the host:

1. In a separate terminal, start the port-forward and leave it running while
   reviewing and merging the PR:

```bash
GITEA_LOCAL_PORT=3031  # use 3032 for OpenShift, or another free local port
kubectl --kubeconfig="$HOME/.kube/kubernaut-hub-config" \
  port-forward -n gitea svc/gitea-http "${GITEA_LOCAL_PORT}:3000"
```

2. Replace `<PR_NUMBER>` with the number printed in `FORWARD_CHANGE_PR_URL` and
   open the corresponding host URL:

```text
http://localhost:3031/kubernaut/demo-operator-oomkill-repo/pulls/<PR_NUMBER>
```

3. Approve the PR with the configured reviewer account, then merge it as the
   reviewer; the workflow waits for that human merge.

Stop the port-forward with `Ctrl-C` after the review is complete. Kind uses port
`3031` by default; OpenShift uses `3032`.

## Cleanup

```bash
./scenarios/operator-oomkill-informer/cleanup.sh [--fleet]
```

## Expected LLM Reasoning

| Field | Expected Value |
|-------|---------------|
| **Root Cause** | Operator pod OOMKilled -- memory usage exceeded the 128Mi limit due to a large number of ConfigMaps in the namespace being cached by the informer |
| **Severity** | critical |
| **Target Resource** | Deployment/demo-controllers-controller (ns: demo-controllers) |
| **Workflow Selected** | Fleet: `increase-memory-limits-gitops-v1`; local/non-GitOps: `increase-memory-limits-v1` |
| **Confidence** | ~0.85 (increasing limits is emergency triage; the real fix is adding label selectors to the informer cache) |
| **Approval** | Required (production environment, critical severity) |

## Acceptance Criteria

- [ ] Operator OOMKills after ConfigMap flood injection
- [ ] `KubePodCrashLooping` alert fires in AlertManager
- [ ] LLM correctly identifies OOMKill as the termination reason
- [ ] LLM identifies ConfigMap volume in the namespace as a contributing factor
- [ ] Fleet selects `increase-memory-limits-gitops-v1`; local mode retains generic `increase-memory-limits-v1`
- [ ] Each fleet remediation adds exactly `128Mi` to the current limit; the increment is not a workflow parameter
- [ ] Confidence >= 0.7
- [ ] Fleet RAR approval is recorded before the Job starts
- [ ] The Job opens a forward-change PR and waits; it never merges, pushes protected `main`, or patches the live Deployment
- [ ] A human reviewer approves and manually merges the PR
- [ ] Argo CD applies the merged revision and the spoke Deployment memory limit increases while requests remain unchanged
- [ ] Effectiveness assessment completes with independent health, alert, metric, and hash evidence while the 300-object flood remains
- [ ] The first EA is genuinely ineffective because alert or health evidence fails; a metrics-only zero is insufficient
- [ ] Gateway cooldown is temporarily `0s`, and the still-firing alert creates a second RR without clearing or reinjecting ConfigMaps
- [ ] The second RR exposes the failed remediation history to platform routing and reaches `ManualReviewRequired`
- [ ] The second RR creates no WFE, RAR, Gitea PR, or additional memory increase
- [ ] The workflow Job remains RR-agnostic; recurrence and escalation are not scripted workflow outcomes

## BDD Specification

```gherkin
Feature: Operator OOMKill remediation from informer cache flooding

  Scenario: Unfiltered ConfigMap informer causes operator OOMKill
    Given a controller-runtime operator "demo-controllers-controller" in namespace "demo-controllers"
      And the operator has an unfiltered ConfigMap informer cache
      And the operator has a 128Mi memory limit

    When 300 ConfigMaps at ~1MB each are created in the namespace
      And the informer deserializes all ConfigMaps into Go structs (3-5x overhead)
      And the in-memory cache exceeds 128Mi
      And the operator is OOMKilled and enters CrashLoopBackOff
      And the KubePodCrashLooping alert fires

    Then Kubernaut detects the crash loop via AlertManager
      And Signal Processing enriches with severity=critical
      And KA diagnoses OOMKill from memory limit exhaustion
      And the LLM selects IncreaseMemoryLimits workflow
      And fleet mode selects the GitOps forward-change workflow
      And the workflow opens a pull request without patching the live Deployment
      And a human reviewer approves and merges the protected-main pull request
      And Argo CD applies the merged desired-state revision to the spoke
       And the operator receives exactly one reviewed +128Mi GitOps increase to 256Mi
       And the ConfigMap flood remains present and the alert remains firing
       And Effectiveness Monitor records alert or health failure for the first EA
       And Gateway cooldown is 0s for this rehearsal
       And the continuing alert creates a second RemediationRequest
       And platform history/routing escalates the second RemediationRequest to ManualReviewRequired
       And the second RemediationRequest creates no WorkflowExecution or pull request
```

## References

- [Protect your Kubernetes Operator from OOMKill](https://developers.redhat.com/articles/2026/06/01/protect-your-kubernetes-operator-oomkill) -- Red Hat Developer blog post
- [kubeflow/spark-operator#2878](https://github.com/kubeflow/spark-operator/pull/2878) -- upstream fix
- [controller-runtime Cache Options](https://pkg.go.dev/sigs.k8s.io/controller-runtime/pkg/cache) -- official documentation
