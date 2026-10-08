#!/usr/bin/env bash
# ImagePullBackOff Demo -- Fleet Spoke Steps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-inventory"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity
platform=$(detect_spoke_platform)

if [ "${platform}" != "ocp" ]; then
    cat >&2 <<'EOF'
ERROR: image-pull-failure Fleet mode requires an authenticated private registry.
The existing fixture uses the OpenShift internal registry; a Kind spoke has no
credential-gated registry configured by this repository, so refusing to create
a false-positive public-image pull failure.
EOF
    exit 2
fi

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${MANIFEST_DIR}"

echo "==> [spoke] Setting up the private registry and workflow template..."
KUBECONFIG="${SPOKE_KUBECONFIG}" NAMESPACE="${NAMESPACE}" \
    bash "${SCRIPT_DIR}/setup-registry.sh"
kubectl_workload wait --for=condition=Available deployment/inventory-api \
    -n "${NAMESPACE}" --timeout=180s
kubectl_workload get pods -n "${NAMESPACE}"

sleep 20
echo "==> [spoke] Deleting registry credentials to trigger ImagePullBackOff..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-expired-credentials.sh"
