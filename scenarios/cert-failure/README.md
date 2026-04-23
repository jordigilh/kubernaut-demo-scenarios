# Scenario #133: cert-manager Certificate Failure (CRD/Operator)

## Overview

Demonstrates Kubernaut detecting a cert-manager Certificate stuck in NotReady because the CA Secret
backing the ClusterIssuer has been deleted, and performing automatic remediation by recreating
the CA Secret to restore certificate issuance.

| | |
|---|---|
| **Signal** | `CertManagerCertNotReady` -- from `certmanager_certificate_ready_status` |
| **Root cause** | CA Secret deleted; ClusterIssuer cannot sign certificates |
| **Remediation** | `fix-certificate-v1` workflow recreates the CA Secret |

## Signal Flow

```
certmanager_certificate_ready_status == 0 for 2m → CertManagerCertNotReady alert
  → Gateway → SP → AA (KA + real LLM)
  → LLM diagnoses missing CA Secret causing Certificate NotReady
  → Selects FixCertificate workflow
  → RO → WE (recreate CA Secret, trigger re-issuance)
  → EM verifies Certificate is Ready
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP with Kubernaut services |
| LLM backend | Real LLM (not mock) via Kubernaut Agent |
| Prometheus | With cert-manager metrics |
| cert-manager | Pre-installed (via `setup-demo-cluster.sh` or manually) |
| Workflow catalog | `fix-certificate-v1` registered in DataStorage |

> **OCP note**: On OpenShift, `run.sh` automatically labels the `cert-manager`
> namespace with `openshift.io/cluster-monitoring=true` so that cert-manager
> ServiceMonitors are scraped by cluster Prometheus (the same instance evaluating
> the PrometheusRule). It also creates a Role/RoleBinding granting the
> `prometheus-k8s` SA read access to endpoints in `cert-manager`. `cleanup.sh`
> removes both the label and the RBAC resources.

### Workflow RBAC

This scenario's remediation workflow runs under a dedicated ServiceAccount with
scoped permissions (created automatically when workflows are seeded via
`platform-helper.sh`):

| Resource | Name |
|----------|------|
| ServiceAccount | `fix-certificate-v1-runner` (in `kubernaut-workflows`) |
| ClusterRole | `fix-certificate-v1-runner` |
| ClusterRoleBinding | `fix-certificate-v1-runner` |

**Permissions**:

| API group | Resource | Verbs |
|-----------|----------|-------|
| `cert-manager.io` | certificates | get, list |
| `cert-manager.io` | clusterissuers | get, list |
| core | secrets | get, list, create, update, delete |

## Running the Scenario

> [!TIP]
> **OCP users**: This walkthrough defaults to Kind. Look for the **OCP** dropdowns
> on steps that differ. For automated runs, prefix with `export PLATFORM=ocp`.
>
> **Time estimate**: ~10 min (Kind) · ~15 min (OCP)

### Automated Run

```bash
./scenarios/cert-failure/run.sh
```

<details>
<summary><strong>OCP</strong></summary>

```bash
export PLATFORM=ocp
./scenarios/cert-failure/run.sh
```

</details>

### Manual Step-by-Step

#### 1. Install cert-manager (if not present)

cert-manager must be pre-installed before running this scenario. `setup-demo-cluster.sh`
handles this automatically. For manual setup:

```bash
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 3m
```

#### 2. Generate CA and deploy scenario resources

```bash
# Generate self-signed CA (run.sh does this automatically)
TMPDIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${TMPDIR}/ca.key" -out "${TMPDIR}/ca.crt" \
  -days 365 -subj "/CN=Demo CA/O=Kubernaut"
kubectl create secret tls demo-ca-key-pair \
  --cert="${TMPDIR}/ca.crt" --key="${TMPDIR}/ca.key" \
  -n cert-manager --dry-run=client -o yaml | kubectl apply -f -
rm -rf "${TMPDIR}"

kubectl apply -f scenarios/cert-failure/manifests/namespace.yaml
kubectl apply -f scenarios/cert-failure/manifests/clusterissuer.yaml
kubectl apply -f scenarios/cert-failure/manifests/certificate.yaml
kubectl apply -f scenarios/cert-failure/manifests/deployment.yaml
kubectl apply -f scenarios/cert-failure/manifests/prometheus-rule.yaml
```

<details>
<summary><strong>OCP</strong></summary>

Label the `cert-manager` namespace so OCP Prometheus discovers its ServiceMonitors,
and grant the `prometheus-k8s` SA read access to cert-manager endpoints:

```bash
kubectl label ns cert-manager openshift.io/cluster-monitoring=true --overwrite

kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: prometheus-k8s-cert-manager
  namespace: cert-manager
rules:
  - apiGroups: [""]
    resources: ["services", "endpoints", "pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: prometheus-k8s-cert-manager
  namespace: cert-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: prometheus-k8s-cert-manager
subjects:
  - kind: ServiceAccount
    name: prometheus-k8s
    namespace: openshift-monitoring
EOF
```

Then deploy:

```bash
kubectl apply -k scenarios/cert-failure/overlays/ocp/
```

</details>

#### 3. Verify healthy state

```bash
kubectl get certificate -n demo-cert-failure
# demo-app-cert should show Ready=True
kubectl get pods -n demo-cert-failure
# All pods should be Running
```

#### 4. Inject failure

```bash
bash scenarios/cert-failure/inject-broken-issuer.sh
```

The script deletes the `demo-ca-key-pair` Secret in cert-manager namespace and triggers
certificate re-issuance. cert-manager will fail to issue because the ClusterIssuer
can no longer sign.

#### 5. Observe Certificate NotReady

```bash
kubectl get certificate -n demo-cert-failure -w
# Certificate status will show Ready=False
```

#### 6. Wait for alert and pipeline

> [!NOTE]
> **OCP timing**: Alerts may take 3-5 minutes to fire on OCP (vs ~2 min on Kind)
> due to the default 30s kube-state-metrics scrape interval and Alertmanager
> group_wait settings.

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert query alertname=CertManagerCertNotReady --alertmanager.url=http://localhost:9093
```

<details>
<summary><strong>OCP</strong></summary>

```bash
kubectl exec -n openshift-monitoring alertmanager-main-0 -- \
  amtool alert query alertname=CertManagerCertNotReady --alertmanager.url=http://localhost:9093
```

</details>

```bash
# Alert fires after 2 min of NotReady
watch kubectl get rr,sp,aia,wfe,ea,notif -n kubernaut-system
```

#### 7. Inspect AI Analysis

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
| **Root Cause** | ClusterIssuer `demo-selfsigned-ca` is not Ready because its backing CA Secret `demo-ca-key-pair` does not exist, blocking TLS certificate issuance for `demo-app-cert`. The missing secret prevents the ClusterIssuer from signing CertificateRequests, leaving the TLS secret `demo-app-tls` absent and pods serving without valid HTTPS. |
| **Severity** | critical |
| **Target Resource** | ClusterIssuer/demo-selfsigned-ca |
| **Workflow Selected** | fix-certificate-v1 |
| **Confidence** | 0.97 |
| **Approval** | not required (staging, high confidence) |

**Key Reasoning Chain:**

1. Detects CertManagerCertNotReady alert in `demo-cert-failure` namespace.
2. Examines Certificates, CertificateRequests — finds `demo-app-cert` stuck NotReady.
3. Traces failure through cert-manager trust chain: Certificate → ClusterIssuer → missing CA Secret.
4. Inspects ClusterIssuer `demo-selfsigned-ca` — confirms `ErrGetKeyPair` for Secret `demo-ca-key-pair`.
5. Identifies that the optional TLS volume mount masks pod-level impact.
6. Selects `fix-certificate-v1` (`FixCertificate` action type) with `ISSUER_NAME=demo-selfsigned-ca`.

> **Why this matters**: Shows the LLM tracing certificate issuance failures through the cert-manager trust chain (Certificate → ClusterIssuer → CA Secret) and correctly targeting a cluster-scoped resource.

#### LLM Investigation Trace (v1.3)

| Turn | Phase | Tool(s) Called | Prompt Chars |
|------|-------|---------------|-------------|
| 1 | RCA | `todo_write` | 4,488 |
| 2 | RCA | `kubectl_get_by_kind_in_namespace` (Deployments) | 4,849 |
| 3 | RCA | `kubectl_get_by_kind_in_namespace` (Certificates) | 14,949 |
| 4 | RCA | `kubectl_get_by_kind_in_namespace` (Pods) | 15,134 |
| 5 | RCA | `todo_write` | 23,104 |
| 6 | RCA | `kubectl_get_by_kind_in_namespace` (CertificateRequests) | 32,344 |
| 7 | RCA | `kubectl_describe`, `kubectl_get_by_name_in_cluster` (ClusterIssuer) | 32,566 |
| 8 | RCA | `kubectl_events` (demo-cert-failure) | 37,215 |
| 9 | RCA | `kubectl_get_by_kind_in_namespace` (Secrets) | 37,461 |
| 10 | RCA | `todo_write`, `kubectl_describe`, `get_namespaced_resource_context`, `get_cluster_resource_context` | 37,594 |
| 11 | Workflow Selection | `todo_write` | 8,513 |
| 12 | Workflow Selection | `todo_write` | 8,882 |
| 13 | Workflow Selection | `list_available_actions` | 9,556 |
| 14 | Workflow Selection | `todo_write` | 9,989 |
| 15 | Workflow Selection | `list_workflows` | 11,002 |
| 16 | Workflow Selection | `todo_write` | 11,417 |
| 17 | Workflow Selection | `get_workflow` (fix-certificate-v1) | 16,228 |
| 18 | Workflow Selection | `todo_write` + submit | 16,587 |

**Summary**: 187,136 total tokens, 14 tool calls (excl. `todo_write`), 18 LLM turns, peak prompt 37,594 chars. Workflow execution completed in ~20s. Full pipeline ~9.5 min (including ~2 min alert wait + ~6 min EA verification).

#### 8. Verify remediation

```bash
kubectl get certificate -n demo-cert-failure
# Certificate should show Ready=True after workflow completes
kubectl get secret demo-ca-key-pair -n cert-manager
# CA Secret should exist (recreated by workflow)
```

#### 9. View notifications

```bash
kubectl get notif -n kubernaut-system --sort-by=.metadata.creationTimestamp
NOTIF=$(kubectl get notif -n kubernaut-system -o name --sort-by=.metadata.creationTimestamp | tail -1)
kubectl get $NOTIF -n kubernaut-system -o jsonpath='{.spec.body}'; echo
```

## Cleanup

```bash
./scenarios/cert-failure/cleanup.sh
```

## BDD Specification

```gherkin
Given a Kind cluster with Kubernaut services and a real LLM backend
  And Prometheus is scraping cert-manager metrics
  And the "fix-certificate-v1" workflow is registered in the DataStorage catalog
  And cert-manager is installed with a CA ClusterIssuer
  And the "demo-app-cert" Certificate is Ready in namespace "demo-cert-failure"

When the CA Secret backing the ClusterIssuer is deleted
  And the TLS secret is deleted to trigger re-issuance
  And cert-manager fails to issue the certificate (ClusterIssuer cannot sign)
  And the CertManagerCertNotReady alert fires (NotReady for 2 min)

Then Kubernaut Gateway receives the alert via Alertmanager webhook
  And Signal Processing enriches the signal with business labels
  And AI Analysis (KA + LLM) diagnoses missing CA Secret as root cause
  And the LLM selects the "FixCertificate" workflow (fix-certificate-v1)
  And Remediation Orchestrator creates a WorkflowExecution
  And Workflow Execution recreates the CA Secret and triggers re-issuance
  And cert-manager successfully issues the certificate
  And Effectiveness Monitor confirms the Certificate is Ready
```

## Acceptance Criteria

- [ ] Certificate starts Ready with valid CA Secret
- [ ] CA Secret deletion causes Certificate to become NotReady
- [ ] Alert fires within 2-3 minutes of Certificate NotReady
- [ ] LLM correctly diagnoses missing CA Secret as root cause
- [ ] FixCertificate workflow recreates the CA Secret
- [ ] cert-manager re-issues the certificate after CA restoration
- [ ] Certificate becomes Ready after remediation
- [ ] EM confirms successful remediation
