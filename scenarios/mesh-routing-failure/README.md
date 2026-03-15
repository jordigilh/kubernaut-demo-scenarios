# Scenario #136: Istio Mesh Routing Failure

## Overview

Demonstrates Kubernaut detecting an Istio-meshed workload with high error rates caused by a restrictive AuthorizationPolicy blocking legitimate traffic. The Istio sidecar returns 403 Forbidden for all inbound requests, causing service unavailability. Kubernaut automatically remediates by removing the blocking policy.

**Signal**: `IstioHighDenyRate` / `IstioRequestsUnauthorized` -- from Istio sidecar metrics (`istio_requests_total` with `response_code="403"`)

**Root cause**: Restrictive Istio AuthorizationPolicy with `action: DENY` and a catch-all rule, denying all inbound traffic

**Remediation**: `fix-authz-policy-v1` workflow removes the blocking AuthorizationPolicy and restores traffic flow

## Signal Flow

```
Istio sidecar metrics: istio_requests_total (response_code=403) > 0 for 3m
  → IstioHighDenyRate / IstioRequestsUnauthorized alert
  → Gateway → SP → AA (HAPI + LLM)
  → LLM detects serviceMesh label, diagnoses AuthorizationPolicy block
  → Selects FixAuthorizationPolicy workflow (fix-authz-policy-v1)
  → RO → WE (remove deny-all AuthorizationPolicy)
  → EM verifies traffic restored, pods Ready
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Kind cluster | Multi-node (`scenarios/kind-config-multinode.yaml`) |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | Scraping Istio sidecar metrics via PodMonitor |
| Istio | Installed (`istioctl install --set profile=demo -y`) |
| Workflow catalog | `fix-authz-policy-v1` registered in DataStorage |

## Automated Run

```bash
./scenarios/mesh-routing-failure/run.sh
```

## Manual Step-by-Step

### 1. Install Istio (if not present)

```bash
istioctl install --set profile=demo -y
kubectl wait --for=condition=Available deployment/istiod -n istio-system --timeout=300s
```

### 2. Deploy workload

```bash
kubectl apply -k scenarios/mesh-routing-failure/manifests/
kubectl wait --for=condition=Available deployment/api-server -n demo-mesh-failure --timeout=120s
kubectl wait --for=condition=Available deployment/traffic-gen -n demo-mesh-failure --timeout=120s
```

The namespace has `istio-injection: enabled`, so Istio automatically injects sidecars into all pods.

### 3. Establish baseline

```bash
# Wait ~30s for healthy traffic between traffic-gen and api-server
kubectl get pods -n demo-mesh-failure
# All pods should have 2/2 containers (app + istio-proxy)
```

### 4. Inject failure

```bash
bash scenarios/mesh-routing-failure/inject-deny-policy.sh
```

The script applies an Istio `AuthorizationPolicy` with `action: DENY` and a catch-all rule, causing the Istio sidecar to deny all inbound traffic with HTTP 403 Forbidden.

### 5. Observe high error rate

```bash
kubectl get pods -n demo-mesh-failure -w
# Verify traffic-gen gets 403 responses:
kubectl exec -n demo-mesh-failure deploy/traffic-gen -- \
  curl -s -o /dev/null -w '%{http_code}' http://api-server:8080/
```

### 6. Wait for alert and pipeline

```bash
# Alert fires after ~3 min of sustained 403 responses
# Check: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
#        then open http://localhost:9090/alerts
kubectl get rr,sp,aa,we,ea -n kubernaut-system -w
```

### 7. Verify remediation

```bash
kubectl get authorizationpolicies.security.istio.io -n demo-mesh-failure
# deny-all-traffic should be removed
kubectl get pods -n demo-mesh-failure
# All pods should be Running and Ready (2/2)
```

## Cleanup

```bash
./scenarios/mesh-routing-failure/cleanup.sh
```

## BDD Specification

```gherkin
Feature: Istio Mesh Routing Failure remediation

  Given a Kind cluster with Kubernaut services and a real LLM backend
    And Prometheus is scraping Istio sidecar metrics via PodMonitor
    And the "fix-authz-policy-v1" workflow is registered in the DataStorage catalog
    And Istio is installed with sidecar injection enabled
    And the "api-server" deployment is meshed in namespace "demo-mesh-failure"
    And the workload is healthy with traffic flowing through the Istio sidecar

  When a restrictive AuthorizationPolicy is applied with action DENY
    And the policy matches all inbound requests
    And the Istio sidecar denies all inbound traffic with 403 Forbidden
    And the IstioHighDenyRate or IstioRequestsUnauthorized alert fires (3 min)

  Then Kubernaut Gateway receives the alert via Alertmanager webhook
    And Signal Processing enriches the signal with business labels
    And AI Analysis (HAPI + LLM) diagnoses AuthorizationPolicy as root cause
    And the LLM selects the "FixAuthorizationPolicy" workflow (fix-authz-policy-v1)
    And Remediation Orchestrator creates a WorkflowExecution
    And Workflow Execution removes the deny-all AuthorizationPolicy
    And traffic is restored through the Istio sidecar
    And Effectiveness Monitor confirms pods are Ready and error rate drops
```

## Acceptance Criteria

- [ ] Namespace has `istio-injection: enabled` label; workload gets Istio sidecar
- [ ] Baseline: traffic flows, pods Ready (2/2 containers), no high error rate
- [ ] deny-all AuthorizationPolicy causes Istio sidecar to return 403 for all inbound traffic
- [ ] PrometheusRule fires IstioHighDenyRate or IstioRequestsUnauthorized within 3 min
- [ ] LLM correctly diagnoses AuthorizationPolicy block as root cause
- [ ] fix-authz-policy-v1 workflow removes the blocking AuthorizationPolicy
- [ ] After remediation, traffic flows and pods are Ready (2/2)
- [ ] EM confirms successful remediation
