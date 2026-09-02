#!/usr/bin/env bash
# Istio Mesh Routing Failure Demo -- Dispatcher
# Scenario #136: AuthorizationPolicy blocks traffic -> fix policy
#
# Usage: ./scenarios/mesh-routing-failure/run.sh [--fleet] [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh -- full pipeline against one
# Kubernaut cluster, as documented there.
#
# Fleet mode: set HUB_KUBECONFIG (Kubernaut control plane) and
# SPOKE_KUBECONFIG (demo workload cluster) to run fleet/run.sh instead,
# which deploys the workload on the spoke and always behaves as
# --alert-only (see scripts/fleet-helper.sh). Requires Istio installed on
# the spoke (fleet/spoke.sh does NOT install it -- `istioctl install
# --set profile=minimal -y --kubeconfig="$SPOKE_KUBECONFIG"` first, same
# prerequisite as local mode). The PodMonitor (prometheus-operator) is
# skipped like every other operator-only kind; fleet mode instead adds a
# raw role:pod scrape job for the istio-proxy sidecar's Envoy stats port.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if fleet_dispatch_requested "$@"; then
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
