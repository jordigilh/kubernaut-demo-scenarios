#!/usr/bin/env bash
# Single-cluster GitOps entrypoint.
#
# The whole scenario runs against the ambient cluster: Gitea, Argo CD,
# Kubernaut, the workload, and the reviewed remediation all stay here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SINGLE_CLUSTER_GITOPS=true

exec bash "${SCRIPT_DIR}/fleet/hub.sh" "$@"
