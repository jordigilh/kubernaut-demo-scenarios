#!/usr/bin/env bash
# Database Connection Saturation Demo -- Fleet Runner (hub + spoke)
#
# Dispatched from ../run.sh when HUB_KUBECONFIG and SPOKE_KUBECONFIG are
# set. Runs spoke.sh then hub.sh in order -- the common single-spoke path.
# For multi-spoke demos, invoke spoke.sh directly against each spoke's
# SPOKE_KUBECONFIG, then hub.sh once (or per spoke) to confirm. The full
# AF/A2A validation pipeline is single-cluster only for now -- drive
# remediation from the Console/APIFrontend on the hub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================="
echo " Database Connection Saturation Demo (L3)"
echo "============================================="
echo ""

bash "${SCRIPT_DIR}/spoke.sh"
echo ""
bash "${SCRIPT_DIR}/hub.sh"
