#!/usr/bin/env bash
# CrashLoopBackOff Demo -- Fleet Spoke Steps
# Scenario #120: Bad release (command override) -> CrashLoopBackOff
#
# Deploys the workload and injects the bad release against SPOKE_KUBECONFIG.
# Touches only the spoke -- safe to invoke directly, multiple times, once
# per spoke cluster if demoing the same fault across several spokes. Run
# ../fleet/hub.sh afterward (once all spokes are done) to confirm the
# alert(s) reached the hub's Alertmanager, or use ../run.sh which runs both
# in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-checkout"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for worker to be healthy..."
kubectl_workload wait --for=condition=Available deployment/worker \
  -n "${NAMESPACE}" --timeout=120s
echo "  Worker is running with valid configuration."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established. Restart count is 0."
echo ""

echo "==> [spoke] Injecting bad release (triggers CrashLoopBackOff)..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-bad-release.sh"
echo ""

echo "==> [spoke] Waiting for CrashLoop alert to fire (~2-3 min)..."
echo "  Pods exit immediately with code 1 (simulated broken binary)."
echo ""
echo "  Waiting for new rollout to begin..."
sleep 10
kubectl_workload get pods -n "${NAMESPACE}"
echo ""
echo "  Waiting for restarts to accumulate..."
sleep 30
kubectl_workload get pods -n "${NAMESPACE}"
echo ""
echo "  The KubePodCrashLooping alert fires after >3 restarts in 10 min."
echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
