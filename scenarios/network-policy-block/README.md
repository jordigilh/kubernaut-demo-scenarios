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
| Cluster | Kind or OCP 4.21+ with Kubernaut services deployed |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (or mock) via HAPI |
| Prometheus | With kube-state-metrics |
| Workflow catalog | `fix-network-policy-v1` registered in DataStorage |

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
kubectl get rr,sp,aa,we,ea -n kubernaut-system -w
```

### 5. Verify remediation

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

## LLM Analysis (OCP observed — rc4)

| Field | Value |
|-------|-------|
| Root Cause | `NetworkPolicy deny-all-ingress is blocking traffic-gen pod's readiness probe from reaching web-frontend service, causing deployment replica mismatch` |
| Severity | `high` |
| Confidence | 0.95 |
| Selected Workflow | `FixNetworkPolicy` (`fix-network-policy-v1`) |
| Approval | Not required |
| Rationale | Investigation confirmed a deny-all NetworkPolicy is blocking legitimate inter-pod traffic. |

The LLM correctly detects `networkIsolated=true` from pod labels and diagnoses the
deny-all NetworkPolicy as the root cause of readiness probe failures. Approval is
not required for this action type.

## Pipeline Timeline (OCP observed — rc4)

| Event | UTC | Delta |
|-------|-----|-------|
| Inject deny-all NetworkPolicy | ~19:33:00 | — |
| `KubeDeploymentReplicasMismatch` fires | 19:36:50 | ~3m 50s |
| RR created → Analyzing | 19:36:51 | +0m 01s |
| AA complete → Executing (no approval) | 19:38:03 | +1m 12s |
| WFE complete → Verifying | 19:38:38 | +0m 35s |
| EA complete → Completed | 19:40:42 | +2m 04s |
| **Total pipeline** | | **3m 52s** |

## Effectiveness Assessment (OCP observed — rc4)

| Field | Value |
|-------|-------|
| Phase | Completed |
| Reason | partial |
| Health Score | 1 |
| Alert Score | pending |
| Metrics Score | pending |

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

- [x] web-frontend deploys with 2 replicas and HTTP probes
- [x] traffic-gen deploys with readiness probe only (no liveness probe)
- [x] Baseline allow policy permits port 8080
- [x] All pods start Running and Ready
- [x] Deny-all NetworkPolicy blocks ingress; traffic-gen readiness fails
- [x] traffic-gen becomes NotReady; deployment shows unavailable replicas
- [x] Alert fires within 3-4 minutes of unavailable replicas
- [x] LLM correctly detects networkIsolated=true and diagnoses NetworkPolicy block
- [x] fix-network-policy-v1 workflow removes the deny-all NetworkPolicy
- [x] traffic-gen readiness recovers; alert self-resolves immediately
- [x] Single RR per incident (no recurring signal after remediation)
- [x] EM confirms successful remediation

## Issue

- #138
- #364
