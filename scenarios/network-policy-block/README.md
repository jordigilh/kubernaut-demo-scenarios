# Scenario #138: NetworkPolicy Traffic Block

## Overview

Demonstrates Kubernaut detecting service connectivity loss caused by a deny-all NetworkPolicy blocking ingress traffic. A traffic-generator pod's readiness probe fails when it cannot reach the target service, triggering a `KubeDeploymentReplicasMismatch` alert. Remediation removes the offending deny-all NetworkPolicy and connectivity is restored.

| | |
|---|---|
| **Signal** | `KubeDeploymentReplicasMismatch` -- from `kube_deployment_status_replicas_unavailable` > 0 on traffic-gen |
| **Root cause** | Deny-all NetworkPolicy blocks all ingress; readiness probes fail |
| **Remediation** | `fix-network-policy-v1` workflow removes the offending deny-all policy |

## Signal Flow

```
deny-all NetworkPolicy blocks inter-pod traffic
  → traffic-gen readiness probe fails (curl to web-frontend times out)
  → traffic-gen becomes NotReady (kube_deployment_status_replicas_unavailable > 0)
  → KubeDeploymentReplicasMismatch alert fires after 3 min
  → Gateway → SP → AA (KA + LLM)
  → LLM detects networkIsolated=true, diagnoses NetworkPolicy block
  → Selects FixNetworkPolicy workflow
  → RO → WE (delete deny-all NetworkPolicy)
  → traffic-gen readiness recovers → alert clears
  → EM verifies all replicas ready
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services deployed |
| LLM backend | Real LLM (or mock) via Kubernaut Agent |
| Prometheus | With kube-state-metrics |
| Workflow catalog | `fix-network-policy-v1` registered in DataStorage |

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `fix-network-policy-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `fix-network-policy-v1-runner` |
| ClusterRoleBinding | `fix-network-policy-v1-runner` |

**Permissions**:

| API group | Resource | Verbs |
|-----------|----------|-------|
| `networking.k8s.io` | networkpolicies | get, list, delete |
| `apps` | deployments | get, list |

## Detected Label

- **networkIsolated**: `true` -- indicates NetworkPolicy is blocking traffic; remediation removes the offending policy

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
./scenarios/network-policy-block/run.sh
```

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/network-policy-block/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Deploy scenario resources

```bash
kubectl apply -f scenarios/network-policy-block/manifests/namespace.yaml
kubectl apply -f scenarios/network-policy-block/manifests/deployment.yaml
kubectl apply -f scenarios/network-policy-block/manifests/networkpolicy-allow.yaml
kubectl apply -f scenarios/network-policy-block/manifests/prometheus-rule.yaml
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl apply -k scenarios/network-policy-block/overlays/ocp/
```

</details>

#### 2. Wait for deployment to be healthy

```bash
kubectl wait --for=condition=Available deployment/web-frontend -n demo-netpol --timeout=120s
kubectl wait --for=condition=Available deployment/traffic-gen -n demo-netpol --timeout=120s
kubectl get pods -n demo-netpol
```

#### 3. Inject deny-all NetworkPolicy

```bash
bash scenarios/network-policy-block/inject-deny-all-netpol.sh
```

The script applies a deny-all NetworkPolicy that blocks all ingress traffic. The traffic-gen readiness probe (curl to web-frontend:8080) will fail, making the pod NotReady.

#### 4. Wait for alert and pipeline

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

```bash
# Alert fires after ~3 min of unavailable replicas
# Query Alertmanager for active alerts

kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert query alertname=KubeDeploymentReplicasMismatch --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=KubeDeploymentReplicasMismatch --alertmanager.url=http://localhost:9093
```

</details>

```bash
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

#### 5. Inspect AI Analysis

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
```

#### Expected LLM Reasoning (v1.3 baseline)

When Kubernaut's AI analysis processes this scenario, the LLM typically reasons as follows:

| Field | Expected Value |
|-------|---------------|
| **Root Cause** | A deny-all-ingress NetworkPolicy injected into demo-netpol is blocking all traffic to web-frontend, causing traffic-gen's readiness probe to time out and the deployment to report zero available replicas. |
| **Severity** | critical |
| **Target Resource** | Deployment/traffic-gen (ns: demo-netpol) |
| **Workflow Selected** | fix-network-policy-v1 |
| **Confidence** | 0.97 |
| **Approval** | not required |
| **Alternatives** | N/A |

**Key Reasoning Chain:**

1. Detects traffic-gen readiness probe failures and connection timeouts to web-frontend.
2. Describes deployment via `kubectl_describe`, lists pods and NetworkPolicies via `kubectl_get_by_kind_in_namespace`.
3. Identifies a deny-all-ingress NetworkPolicy blocking all ingress traffic in the namespace.
4. Uses `get_namespaced_resource_context` and `kubectl_events` to confirm no other contributing factors.
5. Selects `fix-network-policy-v1` workflow (confidence 0.97) to remove the offending policy.

> **Why this matters**: Demonstrates the LLM's ability to correlate application unreachability with NetworkPolicy restrictions rather than blaming the application itself.

#### LLM Investigation Trace (v1.3)

| Phase | Turn | Tool Calls | Prompt (chars) |
|-------|------|-----------|----------------|
| RCA | 1 | `todo_write` | 4,583 |
| RCA | 2 | `kubectl_describe`, `kubectl_get_by_kind_in_namespace` | 4,929 |
| RCA | 3 | `todo_write` | 12,896 |
| RCA | 4 | `kubectl_events`, `kubectl_get_by_kind_in_namespace`, `kubectl_logs` | 13,274 |
| RCA | 5 | `todo_write` | 20,222 |
| RCA | 6 | `get_namespaced_resource_context`, `kubectl_describe` | 20,482 |
| RCA | 7 | `todo_write` | 21,641 |
| RCA | 8 | *submit_result* | 21,699 |
| Workflow | 1 | `todo_write`, `list_available_actions` | 7,716 |
| Workflow | 2 | `todo_write`, `list_available_actions`, `list_workflows` | 14,122 |
| Workflow | 3 | `todo_write`, `get_workflow` | 20,407 |
| Workflow | 4 | `todo_write` | 24,671 |
| Workflow | 5 | *submit_result* | 24,919 |

| Metric | Value |
|--------|-------|
| **Total tokens** | 113,177 (108,513 prompt + 4,664 completion) |
| **Total tool calls** | 19 (10 investigation + 9 todo_write) |
| **LLM turns** | 13 (8 RCA + 5 workflow) |
| **Wall-clock time** | ~2 min 26 s (AA phase) |
| **Peak prompt size** | 24,919 chars |

> **Note**: The LLM used 13 turns across both phases, with `kubectl_describe` and
> `kubectl_get_by_kind_in_namespace` being the primary investigation tools. The LLM
> correctly identified the `deny-all-ingress` NetworkPolicy as the root cause and
> matched it to the `fix-network-policy-v1` workflow with 0.97 confidence.

#### 6. Verify remediation

```bash
kubectl get networkpolicies -n demo-netpol
kubectl get pods -n demo-netpol
# deny-all-ingress should be removed, all pods Running and Ready
# traffic-gen should be Ready (readiness probe recovered)
```

#### 7. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Cleanup

```bash
./scenarios/network-policy-block/cleanup.sh
```

## BDD Specification

```gherkin
Feature: NetworkPolicy Traffic Block remediation

  Scenario: Deny-all NetworkPolicy blocks service connectivity
    Given a Deployment "web-frontend" in namespace "demo-netpol"
    And a traffic-gen Deployment with a readiness probe to web-frontend:8080
    And a baseline NetworkPolicy "allow-web-traffic" permits port 8080
    And all pods are Running and Ready
    When a deny-all NetworkPolicy "deny-all-ingress" is applied
    Then all ingress traffic to web-frontend is blocked
    And the traffic-gen readiness probe fails
    And traffic-gen becomes NotReady
    And the KubeDeploymentReplicasMismatch alert fires (unavailable > 0 for 3 min)

  Scenario: fix-network-policy-v1 remediates traffic block
    Given traffic-gen has unavailable replicas due to blocked connectivity
    And the pipeline detects networkIsolated=true
    When the fix-network-policy-v1 workflow executes
    Then the workflow removes the deny-all NetworkPolicy "deny-all-ingress"
    And the traffic-gen readiness probe recovers
    And traffic-gen becomes Ready
    And the alert self-resolves (no recurring signal)
    And the Deployment has desired replicas available
```

## Acceptance Criteria

- [ ] web-frontend deploys with 2 replicas and HTTP probes
- [ ] traffic-gen deploys with readiness probe only (no liveness probe)
- [ ] Baseline allow policy permits port 8080
- [ ] All pods start Running and Ready
- [ ] Deny-all NetworkPolicy blocks ingress; traffic-gen readiness fails
- [ ] traffic-gen becomes NotReady; deployment shows unavailable replicas
- [ ] Alert fires within 3-4 minutes of unavailable replicas
- [ ] LLM correctly detects networkIsolated=true and diagnoses NetworkPolicy block
- [ ] fix-network-policy-v1 workflow removes the deny-all NetworkPolicy
- [ ] traffic-gen readiness recovers; alert self-resolves immediately
- [ ] Single RR per incident (no recurring signal after remediation)
- [ ] EM confirms successful remediation

## Issue

- #138
- #364
