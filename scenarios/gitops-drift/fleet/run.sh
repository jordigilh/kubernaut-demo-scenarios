#!/usr/bin/env bash
# GitOps Drift Remediation Demo -- Fleet Runner (hub + spoke)
#
# Dispatched from ../run.sh when HUB_KUBECONFIG and SPOKE_KUBECONFIG are
# set. Runs spoke.sh then hub.sh in order. Unlike every other scenario,
# hub.sh does most of the work here (Gitea + ArgoCD live on the hub); see
# its header comment for why.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================="
echo " GitOps Drift Remediation Demo (#125)"
echo "============================================="
echo ""

bash "${SCRIPT_DIR}/spoke.sh"
echo ""
bash "${SCRIPT_DIR}/hub.sh" "$@"
