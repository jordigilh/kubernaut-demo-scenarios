#!/usr/bin/env bash
# cert-manager Certificate Failure Demo -- Fleet Spoke Steps
#
# Deploys the workload and injects the CA-secret failure against
# SPOKE_KUBECONFIG. Requires cert-manager on the spoke (installed with
# --set prometheus.enabled=true, same as local mode). Unlike local mode's
# OCP branch (which labels the cert-manager namespace so OCP's cluster
# Prometheus scrapes it via ServiceMonitor), fleet mode always uses
# fleet_ensure_scrape_job to add a plain static_configs job pointed at
# cert-manager's own metrics Service -- proven live (2026-09-01): no
# operator/ServiceMonitor needed on the spoke, regardless of platform.
# Includes the metric_relabel_configs rename ServiceMonitor scraping would
# have done automatically (namespace -> exported_namespace, to match what
# the PrometheusRule's query expects). Touches only the spoke -- safe to
# invoke directly, multiple times, once per spoke cluster if demoing
# across several spokes. Run ../fleet/hub.sh afterward (once all spokes
# are done) to confirm the alert(s) reached the hub's Alertmanager, or use
# ../run.sh which runs both in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-portal"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

if ! kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get deployment cert-manager -n cert-manager &>/dev/null; then
    echo "ERROR: cert-manager is not installed on the spoke. Install it with:" >&2
    echo "  helm upgrade --install cert-manager jetstack/cert-manager --kubeconfig=\${SPOKE_KUBECONFIG} \\" >&2
    echo "    --namespace cert-manager --create-namespace --set crds.enabled=true --set prometheus.enabled=true --wait" >&2
    exit 1
fi

echo "==> [spoke] Generating self-signed CA key pair..."
# Named CA_TMPDIR, not TMPDIR: assigning the special TMPDIR var here (even
# without `export`) keeps it exported if the parent shell already exports
# it (true by default on macOS), which then breaks every later mktemp -d
# call in this script/process once this directory is removed below.
CA_TMPDIR=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${CA_TMPDIR}/ca.key" -out "${CA_TMPDIR}/ca.crt" \
  -days 365 -subj "/CN=Demo CA/O=Kubernaut" 2>/dev/null
kubectl --kubeconfig="${SPOKE_KUBECONFIG}" create secret tls demo-ca-key-pair \
  --cert="${CA_TMPDIR}/ca.crt" --key="${CA_TMPDIR}/ca.key" \
  -n cert-manager --dry-run=client -o yaml | kubectl --kubeconfig="${SPOKE_KUBECONFIG}" apply -f -
rm -rf "${CA_TMPDIR}"
echo "  CA Secret created in cert-manager namespace on spoke."

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_ensure_kube_state_metrics
fleet_ensure_scrape_job "cert-manager" "cert-manager.cert-manager.svc.cluster.local:9402" \
  "  metric_relabel_configs:
  - source_labels: [namespace]
    target_label: exported_namespace"
fleet_load_prometheus_rule "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"
fleet_reload_spoke_prometheus

echo "==> [spoke] Waiting for Certificate to become Ready..."
CERT_READY=false
for i in $(seq 1 30); do
  STATUS=$(kubectl_workload get certificate demo-app-cert -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$STATUS" = "True" ]; then
    echo "  Certificate is Ready."
    CERT_READY=true
    break
  fi
  echo "  Attempt $i/30: Certificate status=$STATUS, waiting..."
  sleep 5
done
kubectl_workload get certificate -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing healthy baseline (20s)..."
sleep 20
if [ "$CERT_READY" != "true" ]; then
    echo "  WARNING: Certificate never became Ready. Continuing anyway --"
    echo "  the inject step does not depend on certificate readiness."
fi
echo ""

echo "==> [spoke] Injecting failure (deleting CA Secret)..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-broken-issuer.sh"

echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
