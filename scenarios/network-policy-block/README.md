# Scenario #138: NetworkPolicy Traffic Block

## Overview

Demonstrates Kubernaut detecting service connectivity loss caused by a deny-all NetworkPolicy blocking ingress traffic. A traffic-generator pod's readiness probe fails when it cannot reach the target service, triggering a `KubeDeploymentReplicasMismatch` alert. Remediation removes the offending deny-all NetworkPolicy and connectivity is restored.

**Signal**: `KubeDeploymentReplicasMismatch` -- from `kube_deployment_status_replicas_unavailable` > 0 on traffic-gen
**Root cause**: Deny-all NetworkPolicy blocks all ingress; readiness probes fail
**Remediation**: `fix-network-policy-v1` workflow removes the offending deny-all policy

## Signal Flow

```
deny-all NetworkPolicy blocks inter-pod traffic
  → traffic-gen readiness probe fails (curl to web-frontend times out)
  → traffic-gen becomes NotReady (kube_deployment_status_replicas_unavailable > 0)
  → KubeDeploymentReplicasMismatch alert fires after 3 min
  → Gateway → SP → AA (HAPI + LLM)
  → LLM detects networkIsolated=true, diagnoses NetworkPolicy block
  → Selects FixNetworkPolicy workflow
  → RO → WE (delete deny-all NetworkPolicy)
  → traffic-gen readiness recovers → alert clears
  → EM verifies all replicas ready
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Kind cluster | `scenarios/kind-config-singlenode.yaml` |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (or mock) via HAPI |
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

**Permissions**: `networking.k8s.io` networkpolicies (get, list, delete), `apps` deployments (get, list)

## Detected Label

- **networkIsolated**: `true` -- indicates NetworkPolicy is blocking traffic; remediation removes the offending policy

## Automated Run

```bash
./scenarios/network-policy-block/run.sh
```

## Manual Step-by-Step

### 1. Deploy scenario resources

```bash
kubectl apply -f scenarios/network-policy-block/manifests/namespace.yaml
kubectl apply -f scenarios/network-policy-block/manifests/deployment.yaml
kubectl apply -f scenarios/network-policy-block/manifests/networkpolicy-allow.yaml
kubectl apply -f scenarios/network-policy-block/manifests/prometheus-rule.yaml
```

### 2. Wait for deployment to be healthy

```bash
kubectl wait --for=condition=Available deployment/web-frontend -n demo-netpol --timeout=120s
kubectl wait --for=condition=Available deployment/traffic-gen -n demo-netpol --timeout=120s
kubectl get pods -n demo-netpol
```

### 3. Inject deny-all NetworkPolicy

```bash
bash scenarios/network-policy-block/inject-deny-all-netpol.sh
```

The script applies a deny-all NetworkPolicy that blocks all ingress traffic. The traffic-gen readiness probe (curl to web-frontend:8080) will fail, making the pod NotReady.

### 4. Wait for alert and pipeline

```bash
# Alert fires after ~3 min of unavailable replicas
# Check: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
#        then open http://localhost:9090/alerts

# Query Alertmanager for active alerts
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  amtool alert query alertname=KubeDeploymentReplicasMismatch --alertmanager.url=http://localhost:9093

kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system -w
```

### 5. Inspect AI Analysis

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

### 6. Verify remediation

```bash
kubectl get networkpolicies -n demo-netpol
kubectl get pods -n demo-netpol
# deny-all-ingress should be removed, all pods Running and Ready
# traffic-gen should be Ready (readiness probe recovered)
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
