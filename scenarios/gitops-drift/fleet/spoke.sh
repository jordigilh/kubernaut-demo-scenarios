#!/usr/bin/env bash
# GitOps Drift Remediation Demo -- Fleet Spoke Steps
#
# Unlike every other scenario's spoke.sh, this one does NOT deploy the
# workload directly -- ArgoCD (running on the hub) does that, by syncing
# the Application fleet/hub.sh registers and applies. This script only
# prepares the spoke's monitoring so the resulting pods have somewhere to
# report KubePodCrashLooping to once ArgoCD lands them: kube-state-metrics
# (the spoke only scrapes kubelet-cadvisor by default) plus the raw
# Prometheus rule (no prometheus-operator on the spoke to accept a
# PrometheusRule CRD directly).
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

echo "==> [spoke=${SPOKE_KUBECONFIG}] Preparing monitoring (ArgoCD on the hub will deploy the workload here)..."
fleet_ensure_kube_state_metrics
fleet_load_prometheus_rule "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"
fleet_reload_spoke_prometheus
echo "==> [spoke] Ready. Run fleet/hub.sh (or ../run.sh) to register this spoke with ArgoCD and drive the scenario."
