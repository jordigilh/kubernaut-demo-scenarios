#!/usr/bin/env bash
# Operator OOMKill from Informer Cache Flooding -- Dispatcher
# Based on kubeflow/spark-operator#2878.
#
# Usage: ./scenarios/operator-oomkill-informer/run.sh [--fleet] [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs the GitOps hub and spoke co-located on one
# Kind/OpenShift cluster. This keeps the remediation contract identical to
# fleet mode; only the cluster topology changes.
#
# Fleet mode: set HUB_KUBECONFIG + SPOKE_KUBECONFIG to run fleet/run.sh
# instead (see scripts/fleet-helper.sh for platform-aware manifest selection).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if fleet_dispatch_requested "$@"; then
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    LOCAL_KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kubernaut-demo-config}"
    export HUB_KUBECONFIG="${LOCAL_KUBECONFIG}"
    export SPOKE_KUBECONFIG="${LOCAL_KUBECONFIG}"
    export FLEET_COLOCATED=true
    exec bash "${SCRIPT_DIR}/fleet/run.sh" --fleet "$@"
fi
