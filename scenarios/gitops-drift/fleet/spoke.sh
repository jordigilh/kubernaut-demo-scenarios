#!/usr/bin/env bash
# GitOps Drift Remediation Demo -- Fleet Spoke Steps
#
# Unlike every other scenario's spoke.sh, this one does NOT deploy the
# workload directly -- ArgoCD (running on the hub) does that, by syncing
# the Application fleet/hub.sh registers and applies. That Application
# payload includes the scenario's PrometheusRule and ServiceMonitor, so
# monitoring stays ArgoCD-managed end to end: this script only ensures
# kube-state-metrics exists (infra-owned, no-op when the fleet infra
# already deployed it) and deploys nothing imperatively.
#
# Touches only the spoke -- safe to invoke directly, multiple times, once
# per spoke cluster if demoing across several spokes. Run fleet/hub.sh
# afterward to register this spoke with ArgoCD and drive the rest of the
# scenario, or use ../run.sh which runs both in order for the common
# single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Preparing monitoring (ArgoCD on the hub will deploy workload + monitoring here)..."
fleet_ensure_kube_state_metrics
echo "==> [spoke] Ready. Run fleet/hub.sh (or ../run.sh) to register this spoke with ArgoCD and drive the scenario."
