#!/usr/bin/env bash
# Proactive Memory Exhaustion Demo -- Fleet Spoke Steps
#
# Deploys the workload against SPOKE_KUBECONFIG. No fault-injection script
# to run -- the data-processor sidecar leaks memory on its own
# (~12MB/min); this just deploys it and lets the trend build. Touches only
# the spoke -- safe to invoke directly, multiple times, once per spoke
# cluster if demoing across several spokes. Run ../fleet/hub.sh afterward
# (once all spokes are done) to confirm the alert(s) reached the hub's
# Alertmanager, or use ../run.sh which runs both in order for the common
# single-spoke case.
#
# EM configuration (configure_em) from local/run.sh is deliberately
# skipped here: it only affects the downstream validation/approval
# pipeline, which fleet mode never runs (always --alert-only).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-telemetry"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for data-service to be ready..."
kubectl_workload wait --for=condition=Available deployment/data-service \
  -n "${NAMESPACE}" --timeout=120s
echo "  data-service is running (2 pods with data-processor sidecar)."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Memory leak building (~12MB/min per pod)."
echo "    predict_linear will fire once it projects OOM within 30 minutes,"
echo "    typically after 5-7 minutes of trend data."
echo ""
echo "==> [spoke] Fault deployed. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
