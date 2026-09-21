#!/usr/bin/env bash
# Cleanup for Operator OOMKill Informer Cache Flooding scenario
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_MODE=false
if [ -n "${HUB_KUBECONFIG:-}" ] || [ -n "${SPOKE_KUBECONFIG:-}" ]; then
    if [ -z "${HUB_KUBECONFIG:-}" ] || [ -z "${SPOKE_KUBECONFIG:-}" ]; then
        echo "ERROR: fleet cleanup requires both HUB_KUBECONFIG and SPOKE_KUBECONFIG." >&2
        exit 1
    fi
    FLEET_MODE=true
    export KUBECONFIG="${HUB_KUBECONFIG}"
    # shellcheck source=../../scripts/fleet-helper.sh
    source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
    fleet_check_connectivity
fi
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

namespace_exists() {
    if [ "$FLEET_MODE" = true ]; then
        kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get ns "$1"
    else
        kubectl get ns "$1"
    fi
}

echo "==> Cleaning up Operator OOMKill Informer demo..."

if [ "$FLEET_MODE" = true ]; then
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" delete prometheusrule \
      demo-controllers-rules -n demo-controllers --ignore-not-found
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" delete prometheusrule \
      demo-controllers-rules-operator -n openshift-monitoring --ignore-not-found
elif [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-controllers-rules-operator -n openshift-monitoring --ignore-not-found
    kubectl delete prometheusrule demo-controllers-rules -n openshift-monitoring --ignore-not-found
else
    kubectl delete prometheusrule demo-controllers-rules -n demo-controllers --ignore-not-found
fi
if [ "$FLEET_MODE" = true ]; then
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" delete namespace demo-controllers \
      --ignore-not-found --wait=true
else
    kubectl delete namespace demo-controllers --ignore-not-found --wait=true
fi

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while namespace_exists demo-controllers &>/dev/null; do
    sleep 2
    _elapsed=$((_elapsed + 2))
    if [ "$_elapsed" -ge 120 ]; then
        echo "  WARNING: Namespace still terminating after 120s, proceeding..."
        break
    fi
done

purge_pipeline_crds

echo "==> Cleanup complete."
