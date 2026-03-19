# Scenario #136: Istio Mesh Routing Failure

## Demo

<!-- TODO: add demo GIF -->

## Overview

Demonstrates Kubernaut detecting an Istio-meshed workload with high error rates caused by a
restrictive AuthorizationPolicy blocking legitimate traffic. The Istio sidecar returns 403 Forbidden
for all inbound requests, causing service unavailability. Kubernaut automatically remediates by
removing the blocking policy.

**Signal**: `IstioHighDenyRate` / `IstioRequestsUnauthorized` — from Istio sidecar metrics (`istio_requests_total` with `response_code="403"`)
**Root cause**: Restrictive Istio AuthorizationPolicy with `action: DENY` and a catch-all rule, denying all inbound traffic
**Remediation**: `fix-authz-policy-v1` workflow removes the blocking AuthorizationPolicy and restores traffic flow

## Signal Flow

```
Istio sidecar metrics: istio_requests_total (response_code=403) > 0 for 3m
  → IstioHighDenyRate / IstioRequestsUnauthorized alert
  → Gateway → SP → AA (HAPI + LLM)
  → LLM detects serviceMesh label, diagnoses AuthorizationPolicy block
  → Selects FixAuthorizationPolicy workflow (confidence: 0.95)
  → RO → WE (remove deny-all AuthorizationPolicy)
  → EM verifies traffic restored, pods Ready (partial on OCP due to #79)
```

## Prerequisites

| Component | Kind | OCP |
|-----------|------|-----|
| Cluster | Multi-node (`scenarios/kind-config-multinode.yaml`) | OCP 4.x |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed | Same |
| LLM backend | Real LLM (not mock) via HAPI | Same |
| Prometheus | Scraping Istio sidecar metrics via PodMonitor | See [OCP note](#platform-notes--ocp-overlay) |
| Istio | `istioctl install --set profile=demo -y` | OSSM 3.x operator (servicemeshoperator3) |
| Workflow catalog | `fix-authz-policy-v1` registered in DataStorage | Same |

## Automated Run

```bash
./scenarios/mesh-routing-failure/run.sh
```

## Manual Step-by-Step

### 1. Install Istio

**Kind:**

```bash
istioctl install --set profile=demo -y
kubectl wait --for=condition=Available deployment/istiod -n istio-system --timeout=300s
```

**OCP (OSSM 3.x):**

Install the `servicemeshoperator3` from OperatorHub, then create the control plane:

```bash
kubectl create namespace istio-system

cat <<EOF | kubectl apply -f -
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
  namespace: istio-system
spec:
  version: v1.28-latest
  namespace: istio-system
---
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
  namespace: istio-system
spec:
  version: v1.28-latest
  namespace: istio-system
EOF

# Wait for the control plane
kubectl wait --for=condition=Available deployment/istiod -n istio-system --timeout=300s
```

Verify:

```bash
kubectl get istio -n istio-system
```

```
NAME      NAMESPACE      PROFILE   REVISIONS   READY   IN USE   ACTIVE REVISION   STATUS    VERSION        AGE
default   istio-system             1           1       0        default           Healthy   v1.28-latest   2m
```

```bash
kubectl get pods -n istio-system
```

```
NAME                      READY   STATUS    RESTARTS   AGE
istio-cni-node-cqsrt      1/1     Running   0          2m
istio-cni-node-njtlw      1/1     Running   0          2m
istio-cni-node-qwvzj      1/1     Running   0          2m
istio-cni-node-vk9z7      1/1     Running   0          2m
istiod-7cd46f68fb-l4b4v   1/1     Running   0          2m
```

### 2. Deploy workload

```bash
# Kind
kubectl apply -k scenarios/mesh-routing-failure/manifests/

# OCP
kubectl apply -k scenarios/mesh-routing-failure/overlays/ocp/
```

```
namespace/demo-mesh-failure created
configmap/api-server-config created
service/api-server created
deployment.apps/api-server created
deployment.apps/traffic-gen created
podmonitor.monitoring.coreos.com/istio-proxy created
prometheusrule.monitoring.coreos.com/kubernaut-mesh-failure-rules created
```

Wait for deployments:

```bash
kubectl wait --for=condition=Available deployment/api-server -n demo-mesh-failure --timeout=120s
kubectl wait --for=condition=Available deployment/traffic-gen -n demo-mesh-failure --timeout=120s
```

Verify sidecars are injected (2/2 containers):

```bash
kubectl get pods -n demo-mesh-failure
```

```
NAME                           READY   STATUS    RESTARTS   AGE
api-server-74d765b9cf-ppx8p    2/2     Running   0          26s
api-server-74d765b9cf-xrzft    2/2     Running   0          26s
traffic-gen-59fd4bb459-7gtcj   2/2     Running   0          26s
```

### 3. Establish baseline (~30 s)

Wait for traffic-gen to generate healthy requests through the mesh.

### 4. Inject failure

```bash
bash scenarios/mesh-routing-failure/inject-deny-policy.sh
```

```
==> Injecting deny-all AuthorizationPolicy...
authorizationpolicy.security.istio.io/deny-all-traffic created
==> AuthorizationPolicy applied. Istio sidecar will deny all inbound traffic.
    Requests to api-server will return HTTP 403 Forbidden.
```

Verify the deny policy is in effect:

```bash
kubectl exec -n demo-mesh-failure deploy/traffic-gen -- \
  curl -s -o /dev/null -w '%{http_code}' http://api-server:8080/
```

```
403
```

### 5. Wait for alerts (~3 min)

Both `IstioHighDenyRate` and `IstioRequestsUnauthorized` alerts fire once the sustained 403
error rate exceeds the threshold.

```bash
# Check Prometheus rules (OCP)
kubectl exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s http://localhost:9090/api/v1/rules | \
  python3 -c "import sys,json; d=json.load(sys.stdin);
[print(r['name'], r['state']) for g in d['data']['groups'] for r in g['rules'] if 'stio' in r['name'].lower()]"
```

```
IstioHighDenyRate firing
IstioRequestsUnauthorized firing
```

### 6. Pipeline execution

```bash
kubectl get rr -n kubernaut-system \
  -l kubernaut.ai/target-namespace=demo-mesh-failure
```

```
NAME                       PHASE       OUTCOME      AGE
rr-ba256202544e-b85c5d7c   Completed   Remediated   9m
```

**SignalProcessing** classifies the signal:

```
Classified: environment=staging (source=namespace-labels), priority=P1 (source=rego-policy), severity=critical (source=rego-policy)
```

**AIAnalysis** diagnoses the root cause:

```
Root cause: Istio AuthorizationPolicy 'deny-all-traffic' is blocking all traffic in
demo-mesh-failure namespace, causing high deny rates for api-server workload

Contributing factors:
  - Overly restrictive AuthorizationPolicy with DENY action and empty rules
  - Continuous traffic generation hitting blocked endpoints

Selected workflow: FixAuthorizationPolicy (fix-authz-policy-v1)
Confidence: 0.95
Rationale: The investigation clearly identified a deny-all AuthorizationPolicy as the root cause
of high deny rates. This workflow is specifically designed to remove or fix restrictive
AuthorizationPolicies blocking legitimate traffic.
```

**WorkflowExecution** removes the blocking policy with parameters:

```json
{
  "TARGET_NAMESPACE": "demo-mesh-failure",
  "TARGET_POLICY": "deny-all-traffic"
}
```

**EffectivenessAssessment** completes as `partial` on OCP (graceful degradation due to [#79]):

```
Assessment completed: partial
Components assessed: health, hash
```

### 7. Verify remediation

```bash
kubectl get authorizationpolicies.security.istio.io -n demo-mesh-failure
```

```
No resources found in demo-mesh-failure namespace.
```

```bash
kubectl get pods -n demo-mesh-failure
```

```
NAME                           READY   STATUS    RESTARTS   AGE
api-server-74d765b9cf-ppx8p    2/2     Running   0          9m
api-server-74d765b9cf-xrzft    2/2     Running   0          9m
traffic-gen-59fd4bb459-7gtcj   2/2     Running   0          9m
```

## Pipeline Timeline

Observed wall-clock times on OCP 4.21 (single-master, single-worker, OSSM 3.3.0):

| Phase | Duration | Notes |
|-------|----------|-------|
| Deploy + sidecars injected | ~26 s | Pods go to 2/2 with istio-proxy |
| Healthy baseline | 30 s | Fixed delay in `run.sh` |
| Inject deny policy | ~2 s | AuthorizationPolicy applied |
| Alerts pending → firing | ~3 min | `for: 3m` threshold in PrometheusRule |
| Gateway → RR created | ~10 s | AlertManager webhook delivery |
| SP classification | ~0.4 s | Rego policy evaluation |
| AA analysis + workflow selection | ~30 s | LLM call (Claude Sonnet 4 via Vertex AI) |
| WFE (remove authz policy) | ~15 s | Job execution |
| EM stabilization + assessment | ~7 min | 5 min stabilization + 2 min validity window |
| **End-to-end** | **~12 min** | From injection to Completed/Remediated |

## Cleanup

```bash
./scenarios/mesh-routing-failure/cleanup.sh
```

## BDD Specification

```gherkin
Feature: Istio Mesh Routing Failure remediation

  Given a cluster with Kubernaut services and a real LLM backend
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
    And Signal Processing classifies: environment=staging, severity=critical, priority=P1
    And AI Analysis diagnoses AuthorizationPolicy as root cause (confidence >= 0.90)
    And the LLM selects the "FixAuthorizationPolicy" workflow (fix-authz-policy-v1)
    And Remediation Orchestrator creates a WorkflowExecution
    And Workflow Execution removes the deny-all AuthorizationPolicy
    And traffic is restored through the Istio sidecar
    And Effectiveness Monitor confirms remediation (partial on OCP due to #79)
```

## Acceptance Criteria

- [x] Namespace has `istio-injection: enabled` label; workload gets Istio sidecar (2/2 containers)
- [x] Baseline: traffic flows, pods Ready (2/2 containers), no high error rate
- [x] deny-all AuthorizationPolicy causes Istio sidecar to return 403 for all inbound traffic
- [x] PrometheusRule fires IstioHighDenyRate and IstioRequestsUnauthorized within 3 min
- [x] LLM correctly diagnoses AuthorizationPolicy block as root cause (0.95 confidence)
- [x] fix-authz-policy-v1 workflow removes the blocking AuthorizationPolicy
- [x] After remediation, traffic flows and pods are Ready (2/2)
- [x] EM confirms successful remediation (partial on OCP — [#79])

## Platform Notes — OCP Overlay

The `overlays/ocp/` kustomization applies:

1. **Namespace label**: Adds `openshift.io/cluster-monitoring: "true"` for Prometheus PodMonitor discovery.
2. **PrometheusRule**: Removes `release` label (not needed on OCP).
3. **PodMonitor**: Moves to `demo-mesh-failure` namespace and removes `release` label.
4. **api-server**: Swaps to `nginxinc/nginx-unprivileged:1.27-alpine` (OCP SCCs reject root containers).
5. **traffic-gen**: Adds restricted `securityContext` for OCP SCC compliance.

### Additional OCP prerequisites

A `Role`/`RoleBinding` must be created for `prometheus-k8s` in the `demo-mesh-failure` namespace
so Prometheus can scrape the PodMonitor targets:

```bash
kubectl apply -f - <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: prometheus-k8s
  namespace: demo-mesh-failure
rules:
- apiGroups: [""]
  resources: ["services","endpoints","pods"]
  verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: prometheus-k8s
  namespace: demo-mesh-failure
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: prometheus-k8s
subjects:
- kind: ServiceAccount
  name: prometheus-k8s
  namespace: openshift-monitoring
RBAC
```

## Known Issues

| Issue | Impact | Status |
|-------|--------|--------|
| [#79] EM HTTPS endpoint | EM assessment is `partial` on OCP (HTTP→HTTPS mismatch for Prometheus/AlertManager) | Open |
| [#81] Prometheus RBAC for user namespaces | Demo namespaces need manual Role/RoleBinding for `prometheus-k8s` | Open |

[#79]: https://github.com/jordigilh/kubernaut-demo-scenarios/issues/79
[#81]: https://github.com/jordigilh/kubernaut-demo-scenarios/issues/81
