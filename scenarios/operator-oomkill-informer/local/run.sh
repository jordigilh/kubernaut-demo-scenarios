#!/usr/bin/env bash
# Compatibility entrypoint for the co-located GitOps topology.
#
# The operator OOM scenario uses the same GitOps setup and validation path in
# local and fleet environments. Local mode simply points both hub and spoke at
# the same cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kubernaut-demo-config}"
export HUB_KUBECONFIG="${LOCAL_KUBECONFIG}"
export SPOKE_KUBECONFIG="${LOCAL_KUBECONFIG}"
export FLEET_COLOCATED=true

exec bash "${SCRIPT_DIR}/fleet/run.sh" --fleet "$@"
