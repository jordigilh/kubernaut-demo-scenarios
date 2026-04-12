# Scenario #172: Concurrent Cross-Namespace Remediation

## Demo

<!-- TODO: add demo GIF -->

## Overview

Demonstrates how Kubernaut handles the **same incident** (CrashLoopBackOff) across two
namespaces with different risk tolerances, producing different workflow selections and
approval flows running in parallel.

| | |
|---|---|
| **Signal** | `KubePodCrashLooping` — restart count increasing rapidly in both namespaces |
| **Root cause** | Invalid application configuration deployed via ConfigMap swap |
| **Remediation** | **Team Alpha** (staging, high risk tolerance) → `restart-pods-v1` (rolling restart, auto-approved); **Team Beta** (production, low risk tolerance) → `crashloop-rollback-risk-v1` (full rollback, manual approval) |

## Signal Flow

```
Both namespaces injected with bad app config simultaneously

Team Alpha (demo-team-alpha, staging):                Team Beta (demo-team-beta, production):
  kube_pod_container_status_restarts_total ↑            kube_pod_container_status_restarts_total ↑
  → KubePodCrashLooping alert                           → KubePodCrashLooping alert
  → Gateway                                             → Gateway
  → SP (environment=staging, P1,                        → SP (environment=production, P0,
       customLabels: risk_tolerance=high)                     customLabels: risk_tolerance=low)
  → AA selects restart-pods-v1                          → AA selects crashloop-rollback-risk-v1
  → Rego auto-approves (staging)                        → Rego requires manual approval (production)
  → WE: kubectl rollout restart                         → WE: kubectl rollout undo (after approval)
  → EM verifies pods healthy                            → EM verifies pods healthy
```

## Key Mechanism

1. **SignalProcessing Rego policy** maps namespace label `kubernaut.ai/risk-tolerance` into `customLabels` (`risk_tolerance`).
2. **DataStorage** scores workflows by `customLabels` match — `restart-pods-v1` scores higher for `risk_tolerance=high`, `crashloop-rollback-risk-v1` scores higher for `risk_tolerance=low`.
3. **LLM** selects the workflow that aligns with each team's risk tolerance.
4. **Approval Rego policy** auto-approves staging environments (`kubernaut.ai/environment=staging`) and requires manual approval for production (`kubernaut.ai/environment=production`).

## Prerequisites

| Component | Kind | OCP |
|-----------|------|-----|
| Cluster | Kind cluster | OCP 4.x with `openshift.io/cluster-monitoring` support |
| LLM backend | Real LLM (not mock) via HAPI | Same |
| Prometheus | kube-prometheus-stack with kube-state-metrics | OCP built-in monitoring (`openshift-monitoring`) |
| Workflow catalog | `restart-pods-v1` and `crashloop-rollback-risk-v1` registered | Same |
| Container image | `quay.io/kubernaut-cicd/demo-http-server:1.0.0` | Same (platform-neutral) |

### Workflow RBAC

This scenario's remediation workflows run under dedicated ServiceAccounts with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `crashloop-rollback-risk-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `crashloop-rollback-risk-v1-runner` |
| ClusterRoleBinding | `crashloop-rollback-risk-v1-runner` |
| ServiceAccount | `restart-pods-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `restart-pods-v1-runner` |
| ClusterRoleBinding | `restart-pods-v1-runner` |

**Permissions** (`crashloop-rollback-risk-v1-runner`):

| API group | Resources | Verbs |
|-----------|-----------|-------|
| apps | deployments | get, list, patch, update |
| apps | replicasets | get, list |
| core | pods | get, list |

**Permissions** (`restart-pods-v1-runner`):

| API group | Resources | Verbs |
|-----------|-----------|-------|
| apps | deployments | get, list, patch, update |
| apps | replicasets | get, list |
| core | pods | get, list |

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
./scenarios/concurrent-cross-namespace/run.sh
```

Options:
- `--auto-approve` (default): automatically approves Team Beta's manual approval request
- `--interactive`: waits for manual approval via Slack or CLI
- `--no-validate`: skips the validation pipeline

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/concurrent-cross-namespace/run.sh
```

</details>

### Pipeline Timeline (OCP observed)

> **Note**: In this run, both teams received the same workflow (`RollbackDeployment`)
> because the SP policy overwrite bug ([#78](https://github.com/jordigilh/kubernaut-demo-scenarios/issues/78))
> prevented `risk_tolerance` custom labels from being enriched. Once #78 is fixed,
> Alpha should receive `restart-pods-v1` and Beta should receive `crashloop-rollback-risk-v1`.

| Event | Wall clock | Delta |
|-------|-----------|-------|
| Deploy both teams | T+0:00 | — |
| Healthy baseline | T+0:20 | 20 s |
| Inject bad config (both namespaces) | T+0:20 | — |
| Pods enter CrashLoopBackOff | T+0:50 | 30 s |
| KubePodCrashLooping alerts fire | T+3:20 | `for: 3m` |
| Alpha RR created | T+5:38 | Alert → Gateway |
| Beta RR created | T+5:23 | Alert → Gateway |
| SP completes (Alpha: staging/P1) | T+5:38 | Immediate |
| SP completes (Beta: production/P0) | T+5:23 | Immediate |
| AA completes (Alpha: RollbackDeployment, conf 0.9) | T+7:08 | 91 s investigation |
| AA completes (Beta: RollbackDeployment, conf 0.95) | T+6:53 | 90 s investigation |
| Alpha auto-approved (staging Rego policy) | T+7:08 | Immediate |
| Beta awaiting manual approval | T+6:53 | — |
| Beta manually approved | T+9:15 | — |
| WFE completes (both rollback) | T+10:00 | ~45 s job execution |
| EM verifying (stuck — [#79](https://github.com/jordigilh/kubernaut-demo-scenarios/issues/79)) | T+10:00 | HTTP/HTTPS mismatch |
| Both RRs → Completed/Remediated | T+12:00 | EM graceful degradation |
| **Total** | **~12 min** | |

### Manual Step-by-Step

#### 1. Patch the SP policy with risk-tolerance custom labels

The scenario requires a custom SignalProcessing Rego policy that extracts the
`kubernaut.ai/risk-tolerance` namespace label into `customLabels`.

This adds the custom-labels Rego as a separate key to the existing SP ConfigMap
(preserving the unified environment/severity/priority classifiers).

```bash
kubectl patch configmap signalprocessing-policy -n kubernaut-system --type=merge \
  -p "{\"data\":{\"customlabels.rego\":$(cat scenarios/concurrent-cross-namespace/rego/risk-tolerance.rego | jq -Rs .)}}"
kubectl rollout restart deployment/signalprocessing-controller -n kubernaut-system
kubectl rollout status deployment/signalprocessing-controller -n kubernaut-system --timeout=60s
```

#### 2. Register risk-tolerance-aware workflows

```bash
kubectl apply -f deploy/remediation-workflows/concurrent-cross-namespace/ -n kubernaut-system
```

#### 3. Deploy both team workloads

```bash
kubectl apply -k scenarios/concurrent-cross-namespace/manifests/
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/concurrent-cross-namespace/overlays/ocp/
```

</details>

This creates two namespaces:
- `demo-team-alpha` — labeled `kubernaut.ai/environment=staging`, `kubernaut.ai/risk-tolerance=high`
- `demo-team-beta` — labeled `kubernaut.ai/environment=production`, `kubernaut.ai/risk-tolerance=low`

#### 4. Verify healthy state

```bash
kubectl wait --for=condition=Available deployment/worker -n demo-team-alpha --timeout=120s
kubectl wait --for=condition=Available deployment/worker -n demo-team-beta --timeout=120s
kubectl get pods -n demo-team-alpha
kubectl get pods -n demo-team-beta
```

```
NAME                      READY   STATUS    RESTARTS   AGE
worker-68b54dc69c-lwrpm   1/1     Running   0          5s
worker-68b54dc69c-trrfs   1/1     Running   0          5s

NAME                      READY   STATUS    RESTARTS   AGE
worker-68b54dc69c-68krq   1/1     Running   0          5s
worker-68b54dc69c-7ppr9   1/1     Running   0          5s
```

#### 5. Establish baseline and inject bad config

```bash
sleep 20  # healthy baseline
bash scenarios/concurrent-cross-namespace/inject-both.sh
```

The script creates a `worker-config-bad` ConfigMap with an `invalid_directive` flag in both
namespaces and patches the deployments to reference it. The demo-http-server detects this
on startup and exits with `[emerg]`, causing all pods to crash.

#### 6. Observe CrashLoopBackOff in both namespaces

```bash
kubectl get pods -n demo-team-alpha
kubectl get pods -n demo-team-beta
```

```
NAME                      READY   STATUS             RESTARTS      AGE
worker-5b6cc47c55-xvs7t   0/1     CrashLoopBackOff   2 (15s ago)   40s
worker-68b54dc69c-lwrpm   1/1     Running            0             66s
worker-68b54dc69c-trrfs   1/1     Running            0             66s

NAME                      READY   STATUS             RESTARTS      AGE
worker-5b6cc47c55-abc12   0/1     CrashLoopBackOff   2 (14s ago)   40s
worker-68b54dc69c-68krq   1/1     Running            0             66s
worker-68b54dc69c-7ppr9   1/1     Running            0             66s
```

#### 7. Wait for alerts and parallel pipelines

Alerts fire after >3 restarts in 10 min (~3 min with `for: 3m`):

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  amtool alert query alertname=KubePodCrashLooping --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=KubePodCrashLooping --alertmanager.url=http://localhost:9093
```

</details>

```bash
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

```
NAME                       PHASE        OUTCOME   AGE
rr-df3cf7f0a467-f1574ae8   Processing             10s    # Alpha (staging)
rr-3428160586f8-2ea0a4c6   Processing             25s    # Beta (production)
```

The LLM investigates both in parallel (~91 s per investigation):

```
NAME                       PHASE              OUTCOME   AGE
rr-df3cf7f0a467-f1574ae8   Executing                    2m     # Alpha: auto-approved, executing
rr-3428160586f8-2ea0a4c6   AwaitingApproval             2m     # Beta: waiting for manual approval
```

Root cause analysis (from AA):
> *"Pod crashes due to invalid configuration directive
> 'invalid_directive' in ConfigMap worker-config-bad,
> preventing demo-http-server from starting."*
>
> Contributing factors: Invalid configuration directive, Bad ConfigMap
> deployment, Rolling update with malformed config

#### 8. Inspect AI Analysis

```bash
# Get the latest AIA resource
AIA=$(kubectl get aia -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)

# Root cause analysis: summary, severity, and remediation target
kubectl get $AIA -n kubernaut-system -o jsonpath='
Root Cause:  {.status.rootCauseAnalysis.summary}
Severity:    {.status.rootCauseAnalysis.severity}
Target:      {.status.rootCauseAnalysis.remediationTarget.kind}/{.status.rootCauseAnalysis.remediationTarget.name}
'; echo

# Selected workflow and LLM rationale
kubectl get $AIA -n kubernaut-system -o jsonpath='
Workflow:    {.status.selectedWorkflow.workflowId}
Confidence:  {.status.selectedWorkflow.confidence}
Rationale:   {.status.selectedWorkflow.rationale}
'; echo

# Alternative workflows considered
kubectl get $AIA -n kubernaut-system -o jsonpath='{range .status.alternativeWorkflows[*]}  Alt: {.workflowId} (confidence: {.confidence}) -- {.rationale}{"\n"}{end}' # no output if empty

# Approval context and investigation narrative
kubectl get $AIA -n kubernaut-system -o jsonpath='
Approval:    {.status.approvalRequired}
Reason:      {.status.approvalContext.reason}
Confidence:  {.status.approvalContext.confidenceLevel}
'; echo
kubectl get $AIA -n kubernaut-system -o jsonpath='{.status.approvalContext.investigationSummary}'; echo
```

#### 9. Approve Team Beta (if not using --auto-approve)

```bash
# Find the RAR:
kubectl get remediationapprovalrequest -n kubernaut-system
# Approve via status subresource:
RAR_NAME=<rar-name-from-above>
kubectl patch remediationapprovalrequest "$RAR_NAME" -n kubernaut-system \
  --type=merge --subresource=status \
  -p '{"status":{"decision":"Approved","decidedBy":"admin","decisionMessage":"Manual approval"}}'
```

#### 10. Verify remediation

```bash
kubectl get pods -n demo-team-alpha
kubectl get pods -n demo-team-beta
```

```
NAME                      READY   STATUS    RESTARTS   AGE
worker-68b54dc69c-lwrpm   1/1     Running   0          12m
worker-68b54dc69c-trrfs   1/1     Running   0          12m

NAME                      READY   STATUS    RESTARTS   AGE
worker-68b54dc69c-68krq   1/1     Running   0          12m
worker-68b54dc69c-7ppr9   1/1     Running   0          12m
```

```bash
kubectl get rr -n kubernaut-system
```

```
NAME                       PHASE       OUTCOME      AGE
rr-3428160586f8-2ea0a4c6   Completed   Remediated   9m
rr-df3cf7f0a467-f1574ae8   Completed   Remediated   9m
```

Inspect the AA workflow selections:

```bash
kubectl get aianalysis -n kubernaut-system
```

```
NAME                          PHASE       CONFIDENCE   APPROVAL REQUIRED   AGE
ai-rr-3428160586f8-2ea0a4c6   Completed   0.95         true                7m    # Beta: production
ai-rr-df3cf7f0a467-f1574ae8   Completed   0.9          false               7m    # Alpha: staging
```

#### 11. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Pipeline Path (Parallel)

| Team  | Environment | Priority | Approval | Workflow | Action |
|-------|-------------|----------|----------|----------|--------|
| Alpha | staging     | P1       | auto     | `restart-pods-v1` | Rolling restart (faster, simpler) |
| Beta  | production  | P0       | manual   | `crashloop-rollback-risk-v1` | Full rollback (safer, thorough) |

## Platform Notes

### OCP

- The OCP overlay (`overlays/ocp/`) patches the namespace with `openshift.io/cluster-monitoring: "true"` so OCP's built-in Prometheus scrapes the PrometheusRules.
- The `demo-http-server` image is platform-neutral and runs as non-root, so no image swap is needed for OCP.
- PrometheusRule `release` labels are removed (OCP doesn't filter by Helm release).

## Cleanup

```bash
./scenarios/concurrent-cross-namespace/cleanup.sh
```

## BDD Specification

```gherkin
Given a cluster with Kubernaut services and a real LLM backend
  And Prometheus is scraping kube-state-metrics
  And the SP policy includes risk-tolerance custom labels extraction
  And "restart-pods-v1" (customLabels: risk_tolerance=high) is registered
  And "crashloop-rollback-risk-v1" (customLabels: risk_tolerance=low) is registered
  And namespace "demo-team-alpha" has labels environment=staging, risk-tolerance=high
  And namespace "demo-team-beta" has labels environment=production, risk-tolerance=low
  And both "worker" deployments are running healthily

When a bad ConfigMap is deployed in both namespaces simultaneously
  And pods enter CrashLoopBackOff in both namespaces
  And KubePodCrashLooping alerts fire for both namespaces

Then Kubernaut processes both alerts in parallel
  And SP classifies Alpha as staging/P1 with customLabels {risk_tolerance: [high]}
  And SP classifies Beta as production/P0 with customLabels {risk_tolerance: [low]}
  And AA selects restart-pods-v1 for Alpha (high risk tolerance match)
  And AA selects crashloop-rollback-risk-v1 for Beta (low risk tolerance match)
  And Alpha is auto-approved by Rego policy (staging environment)
  And Beta requires manual approval by Rego policy (production environment)
  And after approval, both WorkflowExecutions complete successfully
  And pods in both namespaces return to Running/Ready
  And EM confirms both deployments are healthy
```

## Acceptance Criteria

- [ ] Both team workloads start healthy and serve traffic
- [ ] Bad config injection causes CrashLoopBackOff in both namespaces
- [ ] Alerts fire within 2-3 minutes of first crash per namespace
- [ ] SP classifies Alpha as staging/P1 and Beta as production/P0
- [ ] SP enriches both with correct `risk_tolerance` custom labels
- [ ] LLM selects `restart-pods-v1` for Alpha (high risk tolerance)
- [ ] LLM selects `crashloop-rollback-risk-v1` for Beta (low risk tolerance)
- [ ] Alpha is auto-approved; Beta requires manual approval
- [ ] Both remediations execute successfully in parallel
- [ ] All pods become Running/Ready after remediation
- [ ] EM confirms successful remediation for both teams

## Business Requirements

- **BR-SP-102**: Custom labels enrichment for workflow scoring
- **#172**: Concurrent cross-namespace scenario

## Known Issues

None.
