#!/usr/bin/env bash
# Resource Quota Exhaustion Demo -- Fleet Spoke Steps
# Scenario #171: ResourceQuota prevents pod creation -> LLM escalates to human review
#
# Deploys the scenario against SPOKE_KUBECONFIG. The quota conflict is baked
# into the manifests (3-replica deployment vs 512Mi quota that only fits 2),
# so there is no separate fault-injection step -- applying the manifests is
# the fault. Touches only the spoke -- safe to invoke directly, multiple
# times, once per spoke cluster if demoing across several spokes. Run
# ../fleet/hub.sh afterward (once all spokes are done) to confirm the
# alert(s) reached the hub's Alertmanager, or use ../run.sh which runs both
# in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-platform"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources (3 replicas x 256Mi vs 512Mi quota)..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for partial deployment (2/3 pods will come up)..."
sleep 15
echo ""
echo "  Pod status:"
kubectl_workload get pods -n "${NAMESPACE}"
echo ""
echo "  ReplicaSet status (desired > ready = quota exhausted):"
kubectl_workload get rs -n "${NAMESPACE}"
echo ""
echo "  ResourceQuota usage:"
kubectl_workload describe quota namespace-quota -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Deployment created with quota exceeded from the start."
echo "    Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
