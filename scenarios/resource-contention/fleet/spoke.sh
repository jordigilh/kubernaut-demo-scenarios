#!/usr/bin/env bash
# Resource Contention Demo -- Fleet Spoke Steps
#
# Deploys analytics-worker (polinux/stress, fixed args -- OOMs on its own,
# no separate inject script) against SPOKE_KUBECONFIG. Deliberately does
# NOT start the external-actor revert loop: that script watches
# RemediationRequest phase on the hub while patching the Deployment on the
# spoke, which only makes sense once the AIA/WFE pipeline is actually
# running against this workload -- it isn't, in fleet's alert-only mode
# (see kubernaut-demo-scenarios#423). Touches only the spoke -- safe to
# invoke directly, multiple times, once per spoke cluster if demoing
# across several spokes. Run ../fleet/hub.sh afterward (once all spokes
# are done) to confirm the alert(s) reached the hub's Alertmanager, or use
# ../run.sh which runs both in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-analytics"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_ensure_kube_state_metrics
fleet_load_prometheus_rule "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"
fleet_reload_spoke_prometheus

echo "==> [spoke] analytics-worker deployed (polinux/stress, 64Mi limit, 64M requested -- OOMs immediately)."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""
echo "==> [spoke] Fault self-injecting. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
