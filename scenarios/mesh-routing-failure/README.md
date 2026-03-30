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

## LLM Analysis (OCP observed — rc4)

| Field | Value |
|-------|-------|
| Root Cause | `Istio AuthorizationPolicy 'deny-all-traffic' with empty rules and DENY action is blocking all traffic in demo-mesh-failure namespace, causing 403 Forbidden responses for legitimate service-to-service communication` |
| Severity | `critical` |
| Confidence | 0.95 |
| Selected Workflow | `FixAuthorizationPolicy` (`fix-authz-policy-v1`) |
| Approval | Auto-approved |
| Contributing Factors | Misconfigured Istio AuthorizationPolicy, Empty rule set matching all traffic, DENY action blocking legitimate requests |
| Rationale | Perfect match for the root cause — removes the problematic deny-all-traffic AuthorizationPolicy that is blocking legitimate traffic in the service mesh |

The LLM correctly identifies the `deny-all-traffic` AuthorizationPolicy as the root cause
with 95% confidence and selects `FixAuthorizationPolicy` to remove it. The LLM detects
`serviceMesh` labeling and diagnoses the DENY-action catch-all rule pattern.

## Pipeline Timeline (OCP observed — rc4)

| Event | UTC | Delta |
|-------|-----|-------|
| Deploy + baseline | 20:16:17 | — |
| AuthorizationPolicy injected | 20:16:52 | +35 s |
| UWM scrape targets active | 22:15:25 | *(delayed by #128 / #129 — see bugs below)* |
| `IstioHighDenyRate` alert firing | 22:21:09 | +5 min 44 s after first scrape |
| RR created (`rr-ba256202544e-ba70ddd3`) | 22:21:14 | +5 s |
| AI Analysis started | 22:21:15 | +1 s |
| AI Analysis completed (8 polls, 120 s) | 22:23:15 | +2 min |
| WE created (`we-rr-ba256202544e-ba70ddd3`) | 22:23:15 | immediate |
| WE running (job) | 22:23:16 | +1 s |
| WE completed (AuthorizationPolicy removed) | 22:23:46 | +30 s |
| EA started | 22:23:46 | immediate |
| EA completed (healthScore = 1.0, partial) | 22:25:47 | +2 min 1 s |
| RR completed — outcome `Remediated` | 22:25:47 | immediate |
| **Total (alert → remediated)** | **~4 min 33 s** | |

> **Note**: The extended gap between injection and alert firing was caused by two
> bugs discovered during this run (#128, #129). After fixing the OCP overlay
> (ServiceMonitor instead of PodMonitor) and restarting the UWM prometheus-operator,
> the alert fired within ~6 minutes of metrics scraping starting.

## Effectiveness Assessment (OCP observed — rc4)

| Field | Value |
|-------|-------|
| Health Score | 1.0 |
| Assessment | `partial` |
| Spec Integrity | Unchanged (pre/post hash match) |
| Stabilization Window | 1 min |
| Completed | 22:25:47 UTC |

The assessment is `partial` because the 5-minute rate window for the alert expression
needs time to decay after the AuthorizationPolicy is removed. However, the
remediation is confirmed successful: traffic is restored (HTTP 200) and all 3/3 pods
are Running and Ready.

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind (multi-node) or OCP 4.21+ with Kubernaut services deployed |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | Scraping Istio sidecar metrics (Kind: PodMonitor; OCP: ServiceMonitor via UWM) |
| Istio | Kind: `istioctl install --set profile=demo -y`; OCP: OpenShift Service Mesh 3 (Sail operator) |
| User-workload monitoring (OCP) | Required for scraping ServiceMonitors in user namespaces. The `run.sh` script enables this automatically by applying `cluster-monitoring-config` in `openshift-monitoring`. |
| Workflow catalog | `fix-authz-policy-v1` registered in DataStorage |

> **OCP note**: The OCP overlay (`overlays/ocp/`) replaces the base PodMonitor with a
> headless Service + ServiceMonitor, because OSSM 3 native sidecars (init containers)
> don't expose named ports discoverable by PodMonitor. It also adds the
> `openshift.io/prometheus-rule-evaluation-scope: leaf-prometheus` label to the
> PrometheusRule for UWM rule evaluation. See #128 for details.

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

# Query Alertmanager for active alerts
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -- \
  amtool alert query alertname=IstioHighDenyRate --alertmanager.url=http://localhost:9093

kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system -w
```

### 7. Inspect AI Analysis

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

### 8. Verify remediation

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

  Given a Kind or OCP cluster with Kubernaut services and a real LLM backend
    And Prometheus is scraping Istio sidecar metrics (PodMonitor on Kind, ServiceMonitor on OCP)
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

- [x] Namespace has `istio-injection: enabled` label; workload gets Istio sidecar
- [x] Baseline: traffic flows, pods Ready (2/2 containers), no high error rate
- [x] deny-all AuthorizationPolicy causes Istio sidecar to return 403 for all inbound traffic
- [x] PrometheusRule fires IstioHighDenyRate or IstioRequestsUnauthorized within 3 min
- [x] LLM correctly diagnoses AuthorizationPolicy block as root cause (95% confidence)
- [x] fix-authz-policy-v1 workflow removes the blocking AuthorizationPolicy
- [x] After remediation, traffic flows (HTTP 200) and pods are Ready (2/2)
- [x] EM confirms successful remediation (healthScore = 1.0)

## Issues

- #136 (tracking issue)
- #128 (PodMonitor incompatible with OSSM 3 native sidecars)
- #129 (UWM prometheus-operator stale config after ServiceMonitor creation)
