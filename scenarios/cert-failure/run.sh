#!/usr/bin/env bash
# cert-manager Certificate Failure Demo -- Automated Runner
# Scenario #133: CA Secret deleted -> Certificate NotReady -> fix issuer
#
# Prerequisites:
#   - Kind cluster
#   - Prometheus with cert-manager metrics
#
# Usage: ./scenarios/cert-failure/run.sh
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
