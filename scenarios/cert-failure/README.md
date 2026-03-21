# Scenario #133: cert-manager Certificate Failure (CRD/Operator)

## Overview

Demonstrates Kubernaut detecting a cert-manager Certificate stuck in NotReady because the CA Secret
backing the ClusterIssuer has been deleted, and performing automatic remediation by recreating
the CA Secret to restore certificate issuance.

**Signal**: `CertManagerCertNotReady` -- from `certmanager_certificate_ready_status`
**Root cause**: CA Secret deleted; ClusterIssuer cannot sign certificates
**Remediation**: `fix-certificate-v1` workflow recreates the CA Secret

## Signal Flow

```
certmanager_certificate_ready_status == 0 for 2m → CertManagerCertNotReady alert
  → Gateway → SP → AA (HAPI + real LLM)
  → LLM diagnoses missing CA Secret causing Certificate NotReady
  → Selects FixCertificate workflow
  → RO → WE (recreate CA Secret, trigger re-issuance)
  → EM verifies Certificate is Ready
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Cluster | Kind or OCP 4.21+ with Kubernaut services deployed |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With cert-manager metrics |
| cert-manager | Pre-installed (via `setup-demo-cluster.sh` or manually) |
| openssl | Required for CA key pair generation |
| Workflow catalog | `fix-certificate-v1` registered in DataStorage |

## Automated Run

```bash
./scenarios/cert-failure/run.sh
```

## Manual Step-by-Step

### 1. Install cert-manager (if not present)

cert-manager must be pre-installed before running this scenario. `setup-demo-cluster.sh`
handles this automatically. For manual setup:

```bash
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 3m
```

### 2. Generate CA and deploy scenario resources

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

### 3. Verify healthy state

```bash
kubectl get certificate -n demo-cert-failure
# demo-app-cert should show Ready=True
kubectl get pods -n demo-cert-failure
# All pods should be Running
```

### 4. Inject failure

```bash
bash scenarios/cert-failure/inject-broken-issuer.sh
```

The script deletes the `demo-ca-key-pair` Secret in cert-manager namespace and triggers
certificate re-issuance. cert-manager will fail to issue because the ClusterIssuer
can no longer sign.

### 5. Observe Certificate NotReady

```bash
kubectl get certificate -n demo-cert-failure -w
# Certificate status will show Ready=False
```

### 6. Wait for alert and pipeline

```bash
# Alert fires after 2 min of NotReady
# Check: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
#        then open http://localhost:9090/alerts
kubectl get rr,sp,aa,we,ea -n demo-cert-failure -w
```

### 7. Verify remediation

```bash
kubectl get certificate -n demo-cert-failure
# Certificate should show Ready=True after workflow completes
kubectl get secret demo-ca-key-pair -n cert-manager
# CA Secret should exist (recreated by workflow)
```

## Cleanup

```bash
./scenarios/cert-failure/cleanup.sh
```

## LLM Analysis (OCP observed — rc4)

| Field | Value |
|-------|-------|
| Root Cause | `Certificate issuance failure due to missing CA Secret 'demo-ca-key-pair' backing the ClusterIssuer 'demo-selfsigned-ca'. The cert-manager cannot sign certificates without this CA Secret, leaving the demo-app-cert Certificate stuck in NotReady state.` |
| Severity | `medium` |
| Confidence | 0.95 |
| Selected Workflow | `FixCertificate` (`fix-certificate-v1`) |
| Approval | Not required |
| Rationale | This workflow specifically addresses missing or corrupted CA Secrets backing ClusterIssuers. |

The LLM correctly identifies the missing CA Secret as root cause (not a cert-manager bug)
and selects `FixCertificate` with 95% confidence. Approval is not required because the
severity is `medium` and the environment does not mandate it.

## Pipeline Timeline (OCP observed — rc4)

| Event | UTC | Delta |
|-------|-----|-------|
| Inject (delete CA Secret + renew) | ~19:25:40 | — |
| `CertManagerCertNotReady` fires | 19:26:32 | ~0m 52s |
| RR created → Analyzing | 19:26:38 | +0m 06s |
| AA complete → Executing (no approval) | 19:28:11 | +1m 33s |
| WFE complete → Verifying | 19:28:46 | +0m 35s |
| EA complete → Completed | 19:30:40 | +1m 54s |
| **Total pipeline** | | **4m 08s** |

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
Given a Kind or OCP cluster with Kubernaut services and a real LLM backend
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
  And AI Analysis (HAPI + LLM) diagnoses missing CA Secret as root cause
  And the LLM selects the "FixCertificate" workflow (fix-certificate-v1)
  And Remediation Orchestrator creates a WorkflowExecution
  And Workflow Execution recreates the CA Secret and triggers re-issuance
  And cert-manager successfully issues the certificate
  And Effectiveness Monitor confirms the Certificate is Ready
```

## Acceptance Criteria

- [x] Certificate starts Ready with valid CA Secret
- [x] CA Secret deletion causes Certificate to become NotReady
- [x] Alert fires within 2-3 minutes of Certificate NotReady
- [x] LLM correctly diagnoses missing CA Secret as root cause
- [x] FixCertificate workflow recreates the CA Secret
- [x] cert-manager re-issues the certificate after CA restoration
- [x] Certificate becomes Ready after remediation
- [x] EM confirms successful remediation
