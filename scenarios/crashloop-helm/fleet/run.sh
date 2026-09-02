#!/usr/bin/env bash
# CrashLoopBackOff Helm Demo -- Fleet Runner (hub + spoke)
#
# Dispatched from ../run.sh via --fleet (validated against HUB_KUBECONFIG and
# SPOKE_KUBECONFIG). Runs spoke.sh then hub.sh in order -- the common single-spoke path.
# For multi-spoke demos, invoke spoke.sh directly against each spoke's
# SPOKE_KUBECONFIG, then hub.sh once (or per spoke) to confirm. hub.sh drives the full
# remediation pipeline by default (--alert-only stops after the alert
# instead).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================="
echo " Helm CrashLoopBackOff Remediation Demo (#135)"
echo "============================================="
echo ""

bash "${SCRIPT_DIR}/spoke.sh"
echo ""
bash "${SCRIPT_DIR}/hub.sh" "$@"
