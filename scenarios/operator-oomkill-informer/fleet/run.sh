#!/usr/bin/env bash
# Operator OOMKill from Informer Cache Flooding -- Fleet Runner (hub + spoke)
# Based on kubeflow/spark-operator#2878.
#
# Dispatched from ../run.sh via --fleet (validated against HUB_KUBECONFIG and
# SPOKE_KUBECONFIG). Runs spoke.sh then hub.sh in order -- the common single-spoke path.
# For multi-spoke demos, invoke spoke.sh directly against each spoke's
# SPOKE_KUBECONFIG, then hub.sh once (or per spoke) to confirm.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================="
echo " Operator OOMKill: Informer Cache Flooding"
echo " CVE: kubeflow/spark-operator#2878"
echo "============================================="
echo ""

bash "${SCRIPT_DIR}/spoke.sh"
echo ""
bash "${SCRIPT_DIR}/hub.sh" "$@"
