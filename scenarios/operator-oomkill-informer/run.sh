#!/usr/bin/env bash
# Operator OOMKill from Informer Cache Flooding -- Dispatcher
# Based on kubeflow/spark-operator#2878.
#
# Usage: ./scenarios/operator-oomkill-informer/run.sh [--fleet] [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh (OCP-only -- see local/run.sh and
# README for PrometheusRule namespace assumptions).
#
# Fleet mode: set HUB_KUBECONFIG + SPOKE_KUBECONFIG to run fleet/run.sh
# instead (always --alert-only, works on vanilla Kind spokes since it never
# applies the OCP-specific PrometheusRule CRD -- see scripts/fleet-helper.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if fleet_dispatch_requested "$@"; then
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
