#!/usr/bin/env bash
# RBAC Failure Demo -- Fleet Runner (hub + spoke)
# RoleBinding deleted -> 403 Forbidden -> RestoreRoleBinding
#
# Dispatched from ../run.sh when HUB_KUBECONFIG and SPOKE_KUBECONFIG are
# set. Runs spoke.sh then hub.sh in order -- the common single-spoke path.
# For multi-spoke demos, invoke spoke.sh directly against each spoke's
# SPOKE_KUBECONFIG, then hub.sh once (or per spoke) to confirm.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================="
echo " RBAC Failure Remediation Demo"
echo " RoleBinding deleted -> 403 Forbidden"
echo " -> RestoreRoleBinding"
echo "============================================="
echo ""

bash "${SCRIPT_DIR}/spoke.sh"
echo ""
bash "${SCRIPT_DIR}/hub.sh" "$@"
