#!/usr/bin/env bash
# Orphaned PVC Demo -- Fleet Spoke Steps
#
# Deploys the data-processor workload and creates orphaned PVCs against
# SPOKE_KUBECONFIG. The warning-aware approval Rego patch from
# local/run.sh (Step 1) only steers the downstream validation pipeline,
# which fleet mode never runs -- skipped here. Touches only the spoke --
# safe to invoke directly, multiple times, once per spoke cluster if
# demoing across several spokes. Run ../fleet/hub.sh afterward (once all
# spokes are done) to confirm the alert(s) reached the hub's Alertmanager,
# or use ../run.sh which runs both in order for the common single-spoke
# case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-batch"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for data-processor to be ready..."
kubectl_workload wait --for=condition=Available deployment/data-processor \
  -n "${NAMESPACE}" --timeout=120s
echo "  data-processor is running."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Creating orphaned PVCs from simulated batch jobs..."
# inject-orphan-pvcs.sh reads PLATFORM to decide the StorageClass and pod
# securityContext -- override it to the spoke's platform, not the hub's
# (ambient context stays on the hub throughout fleet mode).
KUBECONFIG="${SPOKE_KUBECONFIG}" PLATFORM="$(detect_spoke_platform)" \
  bash "${SCRIPT_DIR}/inject-orphan-pvcs.sh"

echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
