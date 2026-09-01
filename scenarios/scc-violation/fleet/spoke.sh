#!/usr/bin/env bash
# SCC Violation Demo -- Fleet Spoke Steps
#
# Deploys the workload and injects the privileged-securityContext fault
# against SPOKE_KUBECONFIG. On a Kind spoke, the base namespace's
# pod-security.kubernetes.io/enforce: restricted label rejects the fault the
# same way OpenShift's restricted-v2 SCC does; the OCP overlay (picked up
# automatically when the spoke is OpenShift) doesn't change this, it only
# removes the base's Kind-only fixed runAsUser so SCC keeps auto-assigning
# one as before. Touches only the spoke -- safe to invoke directly, multiple
# times, once per spoke cluster if demoing across several spokes. Run
# ../fleet/hub.sh afterward (once all spokes are done) to confirm the
# alert(s) reached the hub's Alertmanager, or use ../run.sh which runs both
# in order for the common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-agents"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"

echo "==> [spoke] Waiting for healthy deployment..."
kubectl_workload wait --for=condition=Available deployment/metrics-agent \
  -n "${NAMESPACE}" --timeout=120s
echo "  metrics-agent is running with SCC/PSA-compliant configuration."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established."
echo ""

echo "==> [spoke] Injecting privileged requirement (SCC/PSA violation)..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-privileged-requirement.sh"
echo ""

echo "==> [spoke] Waiting for denial and alert (~2 min)..."
sleep 10
kubectl_workload get pods -n "${NAMESPACE}"
echo ""
echo "  FailedCreate events:"
kubectl_workload get events -n "${NAMESPACE}" --field-selector reason=FailedCreate --sort-by='.lastTimestamp' 2>/dev/null | tail -5
echo ""
sleep 30
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
