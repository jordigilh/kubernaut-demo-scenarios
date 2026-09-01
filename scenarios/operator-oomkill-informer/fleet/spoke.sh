#!/usr/bin/env bash
# Operator OOMKill from Informer Cache Flooding -- Fleet Spoke Steps
# Based on kubeflow/spark-operator#2878.
#
# Deploys the operator and floods it with ConfigMaps against
# SPOKE_KUBECONFIG. Touches only the spoke -- safe to invoke directly,
# multiple times, once per spoke cluster if demoing the same fault across
# several spokes. Run ../fleet/hub.sh afterward (once all spokes are done)
# to confirm the alert(s) reached the hub's Alertmanager, or use ../run.sh
# which runs both in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-controllers"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying operator and RBAC..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for operator to be ready..."
kubectl_workload wait --for=condition=Available deployment/demo-controllers-controller \
  -n "${NAMESPACE}" --timeout=120s
echo "  Operator is running with 128Mi memory limit."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing healthy baseline (10s)..."
sleep 10
echo "  Baseline established. Operator healthy, 0 restarts."
echo ""

echo "==> [spoke] Flooding namespace with 100 x 1MB ConfigMaps..."
echo "  This mirrors the attack vector from the Spark Operator CVE."
NAMESPACE="${NAMESPACE}" KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-configmap-flood.sh"
echo ""

echo "==> [spoke] Waiting for operator to OOMKill (~30-60s)..."
sleep 15
kubectl_workload get pods -n "${NAMESPACE}"
echo ""
echo "  Waiting for restarts to accumulate..."
sleep 30
kubectl_workload get pods -n "${NAMESPACE}"
echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
