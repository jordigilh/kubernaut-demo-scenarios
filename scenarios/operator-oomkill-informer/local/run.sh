#!/usr/bin/env bash
# Single-cluster GitOps entrypoint.
#
# The whole scenario runs against the ambient cluster: Gitea, Argo CD,
# Kubernaut, the workload, and the reviewed remediation all stay here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SINGLE_CLUSTER_GITOPS=true
# Keep a plain local invocation local even when a caller's shell retains stale
# fleet variables from an earlier rehearsal. The local contract is ambient
# KUBECONFIG only; it must never infer a spoke from environment leftovers.
export FLEET_MODE=false
export GITOPS_MODE=true
unset HUB_KUBECONFIG SPOKE_KUBECONFIG

exec bash "${SCRIPT_DIR}/fleet/hub.sh" "$@"
