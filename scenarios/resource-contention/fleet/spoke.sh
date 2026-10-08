#!/usr/bin/env bash
# Resource Contention Demo -- Fleet Spoke Steps
#
# Deploys analytics-worker (polinux/stress, fixed args -- OOMs on its own,
# no separate inject script) against SPOKE_KUBECONFIG. The Fleet runner
# starts the external actor after deployment and routes its RR polling to the
# hub. This script touches only the spoke and remains safe to invoke directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-analytics"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${MANIFEST_DIR}"

echo "==> [spoke] analytics-worker deployed (polinux/stress, 64Mi limit, 64M requested -- OOMs immediately)."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""
echo "==> [spoke] Fault self-injecting. The Fleet runner will drive remediation on the hub."
