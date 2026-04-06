#!/usr/bin/env bash
# cert-manager Certificate Failure Demo -- Automated Runner
# Scenario #133: CA Secret deleted -> Certificate NotReady -> fix issuer
#
# Prerequisites:
#   - Kind or OCP cluster with Kubernaut services
#   - Prometheus with cert-manager metrics
#   - cert-manager installed
#
# Usage: ./scenarios/cert-failure/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-cert-failure"

APPROVE_MODE="--auto-approve"
SKIP_VALIDATE=""
for _arg in "$@"; do
    case "$_arg" in
        --auto-approve)  APPROVE_MODE="--auto-approve" ;;
        --interactive)   APPROVE_MODE="--interactive" ;;
        --no-validate)   SKIP_VALIDATE=true ;;
    esac
done

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
require_demo_ready
# shellcheck source=../../scripts/monitoring-helper.sh
source "${SCRIPT_DIR}/../../scripts/monitoring-helper.sh"
require_infra cert-manager
# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

echo "============================================="
echo " cert-manager Certificate Failure Demo (#133)"
echo "============================================="
echo ""

# Step 0: Clean up stale alerts/RRs from any previous run (#193)
ensure_clean_slate "${NAMESPACE}"

# Step 1: Generate a self-signed CA and create the CA Secret
echo "==> Step 1: Generating self-signed CA key pair..."
TMPDIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${TMPDIR}/ca.key" -out "${TMPDIR}/ca.crt" \
  -days 365 -subj "/CN=Demo CA/O=Kubernaut"
kubectl create secret tls demo-ca-key-pair \
  --cert="${TMPDIR}/ca.crt" --key="${TMPDIR}/ca.key" \
  -n cert-manager --dry-run=client -o yaml | kubectl apply -f -
rm -rf "${TMPDIR}"
echo "  CA Secret created in cert-manager namespace."

# Step 2: Deploy scenario resources
echo "==> Step 2: Deploying scenario resources..."
if [ "$PLATFORM" = "ocp" ]; then
    # Label cert-manager namespace so its ServiceMonitor is scraped by cluster
    # Prometheus (same instance evaluating the PrometheusRule in demo-cert-failure).
    # Without this, cert-manager metrics go to user-workload Prometheus and the
    # alert rule in cluster Prometheus never fires (#290).
    # NOTE: This moves ALL ServiceMonitors in cert-manager ns to cluster Prometheus.
    # cleanup.sh removes this label to restore the original state.
    kubectl label namespace cert-manager openshift.io/cluster-monitoring=true --overwrite
    echo "  Labeled cert-manager namespace for cluster Prometheus scraping."
    # The namespace label alone is not sufficient: the cluster Prometheus SA
    # needs RBAC to discover endpoints in cert-manager for scraping.
    kubectl apply -f - <<'RBAC'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: prometheus-k8s-read
  namespace: cert-manager
rules:
- apiGroups: [""]
  resources: [endpoints, services, pods]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: prometheus-k8s-read-binding
  namespace: cert-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: prometheus-k8s-read
subjects:
- kind: ServiceAccount
  name: prometheus-k8s
  namespace: openshift-monitoring
RBAC
fi
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 3: Wait for certificate to be issued
echo "==> Step 3: Waiting for Certificate to become Ready..."
CERT_READY=false
for i in $(seq 1 30); do
  STATUS=$(kubectl get certificate demo-app-cert -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$STATUS" = "True" ]; then
    echo "  Certificate is Ready."
    CERT_READY=true
    break
  fi
  echo "  Attempt $i/30: Certificate status=$STATUS, waiting..."
  sleep 5
done

kubectl get certificate -n "${NAMESPACE}"
echo ""

# Step 4: Baseline
echo "==> Step 4: Establishing healthy baseline (20s)..."
if [ "$PLATFORM" = "ocp" ]; then
    echo "  Waiting for cluster Prometheus to scrape cert-manager metrics..."
    for i in $(seq 1 12); do
        if kubectl get --raw "/api/v1/namespaces/openshift-monitoring/services/prometheus-k8s:web/proxy/api/v1/query?query=certmanager_certificate_ready_status" 2>/dev/null \
           | grep -q '"result":\[{'; then
            echo "  cert-manager metrics available in cluster Prometheus (attempt $i)."
            break
        fi
        [ "$i" -eq 12 ] && echo "  WARNING: cert-manager metrics not yet visible after 60s. Proceeding anyway."
        sleep 5
    done
fi
sleep 20
if [ "$CERT_READY" = "true" ]; then
    echo "  Baseline established. Certificate is Ready, workload is healthy."
else
    echo "  WARNING: Certificate never became Ready after 30 attempts."
    echo "  Continuing anyway — the inject step does not depend on certificate readiness."
fi
echo ""

# Step 5: Inject failure
echo "==> Step 5: Injecting failure (deleting CA Secret)..."
bash "${SCRIPT_DIR}/inject-broken-issuer.sh"
echo ""

# Step 6: Wait for alert
echo "==> Step 6: Waiting for CertManagerCertNotReady alert to fire (~2-3 min)..."
echo "  cert-manager will fail to re-issue the certificate."
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""

# Step 7: Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
