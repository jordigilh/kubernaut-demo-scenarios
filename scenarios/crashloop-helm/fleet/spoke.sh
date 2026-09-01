#!/usr/bin/env bash
# CrashLoopBackOff Helm Demo -- Fleet Spoke Steps
#
# Installs the workload via Helm (--kubeconfig pointed at the spoke) and
# injects the bad config against SPOKE_KUBECONFIG. Touches only the spoke --
# safe to invoke directly, multiple times, once per spoke cluster if
# demoing across several spokes. Run ../fleet/hub.sh afterward (once all
# spokes are done) to confirm the alert(s) reached the hub's Alertmanager,
# or use ../run.sh which runs both in order for the common single-spoke
# case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-storefront"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying namespace and alerting rules..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Installing workload via Helm chart..."
SPOKE_PLATFORM_DETECTED=$(detect_spoke_platform)
HELM_VALUES_ARGS=""
if [ "$SPOKE_PLATFORM_DETECTED" = "ocp" ]; then
    HELM_VALUES_ARGS="-f ${SCRIPT_DIR}/chart/values-ocp.yaml"
fi
# shellcheck disable=SC2086
helm --kubeconfig="${SPOKE_KUBECONFIG}" upgrade --install demo-storefront "${SCRIPT_DIR}/chart" \
  -n "${NAMESPACE}" --wait --timeout 120s ${HELM_VALUES_ARGS}
echo "  Helm release installed. Deployment has app.kubernetes.io/managed-by: Helm label."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established."
echo ""

echo "==> [spoke] Injecting invalid nginx config via helm upgrade..."
# inject-bad-config.sh sources platform-helper.sh, which auto-detects
# PLATFORM from the ambient kubectl context if not already set -- override
# it here so it picks up the spoke's platform, not the hub's (ambient
# context stays on the hub throughout fleet mode).
KUBECONFIG="${SPOKE_KUBECONFIG}" PLATFORM="${SPOKE_PLATFORM_DETECTED}" \
  bash "${SCRIPT_DIR}/inject-bad-config.sh"
echo ""
echo "  Waiting for pods to start crashing..."
sleep 10
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
