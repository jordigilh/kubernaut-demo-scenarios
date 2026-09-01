#!/usr/bin/env bash
# Concurrent Cross-Namespace Demo -- Fleet Spoke Steps
#
# Deploys both team-alpha and team-beta workers and injects bad config into
# both simultaneously, against SPOKE_KUBECONFIG. The risk-tolerance SP
# policy injection, force_production_approval, and RemediationWorkflow
# registration from local/run.sh are all downstream-pipeline steering --
# skipped here since fleet mode never runs validate.sh. Touches only the
# spoke -- safe to invoke directly, multiple times, once per spoke cluster
# if demoing across several spokes. Run ../fleet/hub.sh afterward (once
# all spokes are done) to confirm the alert(s) reached the hub's
# Alertmanager, or use ../run.sh which runs both in order for the common
# single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying team-alpha and team-beta workloads..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
# Two PrometheusRules, one per team namespace -- not the usual single
# manifests/prometheus-rule.yaml.
fleet_ensure_kube_state_metrics
fleet_load_prometheus_rule "${SCRIPT_DIR}/manifests/team-alpha/prometheus-rule.yaml"
fleet_load_prometheus_rule "${SCRIPT_DIR}/manifests/team-beta/prometheus-rule.yaml"
fleet_reload_spoke_prometheus

echo "==> [spoke] Waiting for both deployments to be healthy..."
kubectl_workload wait --for=condition=Available deployment/worker -n demo-team-alpha --timeout=120s
kubectl_workload wait --for=condition=Available deployment/worker -n demo-team-beta --timeout=120s
echo "  Both teams running."
echo ""

echo "==> [spoke] Establishing healthy baseline (20s)..."
sleep 20
echo ""

echo "==> [spoke] Injecting bad config into both namespaces simultaneously..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-both.sh"

echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
