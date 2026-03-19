# Scenario #133: cert-manager Certificate Failure (CRD/Operator)

## Demo

<!-- TODO: add demo GIF -->

## Overview

Demonstrates Kubernaut detecting a cert-manager Certificate stuck in NotReady because the CA Secret
backing the ClusterIssuer has been deleted, and performing automatic remediation by recreating
the CA Secret to restore certificate issuance.

**Signal**: `CertManagerCertNotReady` — from `certmanager_certificate_ready_status`
**Root cause**: CA Secret deleted; ClusterIssuer cannot sign certificates
**Remediation**: `fix-certificate-v1` workflow recreates the CA Secret

## Signal Flow

```
certmanager_certificate_ready_status == 0 for 2m → CertManagerCertNotReady alert
  → Gateway → SP → AA (HAPI + real LLM)
  → LLM diagnoses missing CA Secret causing Certificate NotReady
  → Selects FixCertificate workflow (confidence: 0.95)
  → RO → WE (recreate CA Secret, trigger re-issuance)
  → EM verifies Certificate is Ready
```

## Prerequisites

| Component | Kind | OCP |
|-----------|------|-----|
| Cluster | `scenarios/kind-config-singlenode.yaml` | OCP 4.x |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed | Same |
| LLM backend | Real LLM (not mock) via HAPI | Same |
| Prometheus | With cert-manager metrics | See [OCP note](#platform-notes--ocp-overlay) |
| cert-manager | Pre-installed (via `setup-demo-cluster.sh`) | OpenShift cert-manager operator |
| Workflow catalog | `fix-certificate-v1` registered in DataStorage | Same |

## Automated Run

```bash
./scenarios/cert-failure/run.sh
```

> **Known issue (OCP):** The kustomization includes a placeholder `ca-secret.yaml` with empty
> PEM data that overwrites the real CA Secret generated in Step 1. See [#80].
> Workaround: after `run.sh` reports Step 2, re-create the CA Secret manually:
>
> ```bash
> TMPDIR=$(mktemp -d)
> openssl req -x509 -newkey rsa:2048 -nodes \
>   -keyout "${TMPDIR}/ca.key" -out "${TMPDIR}/ca.crt" \
>   -days 365 -subj "/CN=Demo CA/O=Kubernaut"
> kubectl create secret tls demo-ca-key-pair \
>   --cert="${TMPDIR}/ca.crt" --key="${TMPDIR}/ca.key" \
>   -n cert-manager --dry-run=client -o yaml | kubectl apply -f -
> rm -rf "${TMPDIR}"
> ```

## Manual Step-by-Step

### 1. Install cert-manager (if not present)

cert-manager must be pre-installed before running this scenario. `setup-demo-cluster.sh`
handles this automatically.

**Kind:**

```bash
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 3m
```

**OCP:**

```bash
# Install via OperatorHub (openshift-cert-manager-operator), then verify:
kubectl get pods -n cert-manager
```

```
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-59ccb4bb6b-6bvfj              1/1     Running   0          6h
cert-manager-cainjector-5b4bf68748-n785w   1/1     Running   0          6h
cert-manager-webhook-fd44f5cbb-s97s2       1/1     Running   0          6h
```

### 2. Generate CA and deploy scenario resources

```bash
# Generate self-signed CA
TMPDIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${TMPDIR}/ca.key" -out "${TMPDIR}/ca.crt" \
  -days 365 -subj "/CN=Demo CA/O=Kubernaut"
kubectl create secret tls demo-ca-key-pair \
  --cert="${TMPDIR}/ca.crt" --key="${TMPDIR}/ca.key" \
  -n cert-manager --dry-run=client -o yaml | kubectl apply -f -
rm -rf "${TMPDIR}"
```

```
secret/demo-ca-key-pair created
  CA Secret created in cert-manager namespace.
```

Apply resources (use OCP overlay on OpenShift):

```bash
# Kind
kubectl apply -k scenarios/cert-failure/manifests/

# OCP
kubectl apply -k scenarios/cert-failure/overlays/ocp/
```

```
namespace/demo-cert-failure created
secret/demo-ca-key-pair configured
service/demo-app created
deployment.apps/demo-app created
certificate.cert-manager.io/demo-app-cert created
clusterissuer.cert-manager.io/demo-selfsigned-ca created
prometheusrule.monitoring.coreos.com/kubernaut-cert-failure-rules created
```

### 3. Verify healthy state

```bash
kubectl get certificate -n demo-cert-failure
```

```
NAME            READY   SECRET         AGE
demo-app-cert   True    demo-app-tls   102s
```

```bash
kubectl get pods -n demo-cert-failure
```

```
NAME                        READY   STATUS    RESTARTS   AGE
demo-app-5c656878dd-2wdlv   1/1     Running   0          102s
demo-app-5c656878dd-6nx25   1/1     Running   0          102s
```

### 4. Establish baseline

Wait 20 seconds for Prometheus to scrape healthy cert-manager metrics.

### 5. Inject failure

```bash
bash scenarios/cert-failure/inject-broken-issuer.sh
```

```
==> Deleting CA Secret that backs the ClusterIssuer...
secret "demo-ca-key-pair" deleted
==> Triggering certificate re-issuance to force failure detection...
secret "demo-app-tls" deleted
==> Renewing certificate to trigger immediate re-issuance attempt...
certificate.cert-manager.io/demo-app-cert annotated
==> CA Secret deleted. cert-manager will fail to issue demo-app-cert.
    ClusterIssuer 'demo-selfsigned-ca' can no longer sign certificates.
```

### 6. Observe Certificate NotReady

```bash
kubectl get certificate -n demo-cert-failure
```

```
NAME            READY   SECRET         AGE
demo-app-cert   False   demo-app-tls   3m
```

The ClusterIssuer is also degraded:

```bash
kubectl get clusterissuer demo-selfsigned-ca -o jsonpath='{.status.conditions[0].message}'
```

```
Error getting keypair for CA issuer: error decoding certificate PEM block: no valid certificates found
```

### 7. Wait for alert (~3 min after injection)

The `CertManagerCertNotReady` alert fires once the certificate has been NotReady for 2 minutes
(configured via the `for: 3m` threshold in the PrometheusRule, with 2 min for the metric to
propagate).

```bash
# Check Prometheus rules
kubectl exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  curl -s http://localhost:9090/api/v1/rules | \
  python3 -c "import sys,json; d=json.load(sys.stdin);
[print(r['name'], r['state']) for g in d['data']['groups'] for r in g['rules'] if 'Cert' in r['name']]"
```

```
CertManagerCertNotReady firing
```

### 8. Pipeline execution

Once the alert reaches Kubernaut Gateway via AlertManager, the pipeline runs:

```bash
kubectl get rr -n kubernaut-system \
  -l kubernaut.ai/target-namespace=demo-cert-failure
```

```
NAME                       PHASE       OUTCOME      AGE
rr-c82834669789-9e2f75df   Completed   Remediated   5m
```

**SignalProcessing** classifies the signal:

```
Classified: environment=staging (source=namespace-labels), priority=P1 (source=rego-policy), severity=critical (source=rego-policy)
```

**AIAnalysis** diagnoses the root cause:

```
Root cause: Certificate demo-app-cert is stuck in NotReady state because the ClusterIssuer
demo-selfsigned-ca cannot function due to missing CA Secret demo-ca-key-pair

Contributing factors:
  - Missing CA Secret demo-ca-key-pair
  - ClusterIssuer demo-selfsigned-ca in NotReady state

Selected workflow: FixCertificate (fix-certificate-v1)
Confidence: 0.95
Rationale: This workflow specifically addresses the root cause by recreating the missing CA
Secret that is preventing the ClusterIssuer from functioning.
```

**WorkflowExecution** recreates the CA Secret with parameters:

```json
{
  "CA_SECRET_NAME": "demo-ca-key-pair",
  "CA_SECRET_NAMESPACE": "cert-manager",
  "ISSUER_NAME": "demo-selfsigned-ca",
  "TARGET_CERTIFICATE": "demo-app-cert",
  "TARGET_NAMESPACE": "demo-cert-failure"
}
```

### 9. Verify remediation

```bash
kubectl get certificate -n demo-cert-failure
```

```
NAME            READY   SECRET         AGE
demo-app-cert   True    demo-app-tls   111m
```

```bash
kubectl get secret demo-ca-key-pair -n cert-manager
```

```
NAME               TYPE                DATA   AGE
demo-ca-key-pair   kubernetes.io/tls   2      83m
```

## Pipeline Timeline

Observed wall-clock times on OCP 4.21 (single-master, single-worker):

| Phase | Duration | Notes |
|-------|----------|-------|
| Deploy + cert Ready | ~100 s | cert-manager issues certificate from CA |
| Healthy baseline | 20 s | Fixed delay in `run.sh` |
| Inject failure | ~2 s | Delete CA Secret + trigger re-issuance |
| Alert pending → firing | ~3 min | `for: 3m` threshold in PrometheusRule |
| Gateway → RR created | ~10 s | AlertManager webhook delivery |
| SP classification | ~5 s | Rego policy evaluation |
| AA analysis + workflow selection | ~30 s | LLM call (Claude Sonnet 4 via Vertex AI) |
| WFE (recreate CA Secret) | ~15 s | Job execution |
| EM verification | Blocked by [#79] | HTTPS endpoint issue on OCP |
| **End-to-end** | **~5 min** | From injection to Completed/Remediated |

## Cleanup

```bash
./scenarios/cert-failure/cleanup.sh
```

## BDD Specification

```gherkin
Given a cluster with Kubernaut services and a real LLM backend
  And Prometheus is scraping cert-manager metrics
  And the "fix-certificate-v1" workflow is registered in the DataStorage catalog
  And cert-manager is installed with a CA ClusterIssuer
  And the "demo-app-cert" Certificate is Ready in namespace "demo-cert-failure"

When the CA Secret backing the ClusterIssuer is deleted
  And the TLS secret is deleted to trigger re-issuance
  And cert-manager fails to issue the certificate (ClusterIssuer cannot sign)
  And the CertManagerCertNotReady alert fires (NotReady for 2+ min)

Then Kubernaut Gateway receives the alert via Alertmanager webhook
  And Signal Processing classifies: environment=staging, severity=critical, priority=P1
  And AI Analysis diagnoses missing CA Secret as root cause (confidence >= 0.90)
  And the LLM selects the "FixCertificate" workflow (fix-certificate-v1)
  And Remediation Orchestrator creates a WorkflowExecution
  And Workflow Execution recreates the CA Secret and triggers re-issuance
  And cert-manager successfully issues the certificate
  And Effectiveness Monitor confirms the Certificate is Ready
```

## Acceptance Criteria

- [x] Certificate starts Ready with valid CA Secret
- [x] CA Secret deletion causes Certificate to become NotReady
- [x] Alert fires within 3 minutes of Certificate NotReady
- [x] LLM correctly diagnoses missing CA Secret as root cause (0.95 confidence)
- [x] FixCertificate workflow recreates the CA Secret
- [x] cert-manager re-issues the certificate after CA restoration
- [x] Certificate becomes Ready after remediation
- [ ] EM confirms successful remediation (blocked by [#79] on OCP)

## Platform Notes — OCP Overlay

The `overlays/ocp/` kustomization applies three changes:

1. **Namespace label**: Adds `openshift.io/cluster-monitoring: "true"` to `demo-cert-failure` for Prometheus scraping.
2. **nginx-unprivileged**: Replaces `nginx:1.27-alpine` with `nginxinc/nginx-unprivileged:1.27-alpine` (OCP SCCs reject root containers).
3. **PrometheusRule**: Removes the `release` label (not needed on OCP; Kind uses it for kube-prometheus-stack selector).

### Additional OCP prerequisites

cert-manager metrics are **not scraped by default** on OCP. You must:

1. Label the `cert-manager` namespace: `kubectl label namespace cert-manager openshift.io/cluster-monitoring=true`
2. Create a `ServiceMonitor` in `cert-manager` namespace targeting port `tcp-prometheus-servicemonitor`
3. Create a `Role`/`RoleBinding` for `prometheus-k8s` in the `cert-manager` namespace

See [#81] for full details and commands.

Demo namespace RBAC is also required for `demo-cert-failure`:

```bash
kubectl apply -f - <<RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: prometheus-k8s
  namespace: demo-cert-failure
rules:
- apiGroups: [""]
  resources: ["services","endpoints","pods"]
  verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: prometheus-k8s
  namespace: demo-cert-failure
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
| [#80] CA Secret placeholder clobber | Certificate never becomes Ready; requires manual re-creation of CA Secret | Open |
| [#81] OCP cert-manager metrics not scraped | Alert never fires without ServiceMonitor + RBAC | Open |
| [#79] EM HTTPS endpoint | EM cannot verify remediation on OCP (HTTP→HTTPS mismatch) | Open |

[#79]: https://github.com/jordigilh/kubernaut-demo-scenarios/issues/79
[#80]: https://github.com/jordigilh/kubernaut-demo-scenarios/issues/80
[#81]: https://github.com/jordigilh/kubernaut-demo-scenarios/issues/81
