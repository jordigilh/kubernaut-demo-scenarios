#!/usr/bin/env bash
# GitOps Drift Remediation Demo -- Dispatcher
# Scenario #125: Signal != RCA (Pod crash -> ConfigMap is root cause)
#
# Usage: ./scenarios/gitops-drift/run.sh [--fleet] [setup|inject|all] [--auto-approve|--interactive|--alert-only|--no-validate]
#
# Single cluster (default): runs local/run.sh -- full pipeline against one
# Kubernaut cluster, as documented there.
#
# Fleet mode: pass --fleet and set HUB_KUBECONFIG and SPOKE_KUBECONFIG to run
# fleet/run.sh instead. Gitea and ArgoCD both run on the HUB (a real deployment's
# GitOps-hub cluster holds the repo credentials); the target workload runs
# on the SPOKE, alongside the rest of fleet's monitoring stack. ArgoCD
# reaches the spoke as a registered remote cluster and syncs the
# Application onto it over the wire -- the real cross-cluster mechanics,
# not a simulation. The full AIA/WFE pipeline runs on the hub after the
# spoke alert arrives, exercising the target-cluster/execution-cluster split
# kubernaut#2326 added (RemediationWorkflow.spec.execution.clusterId).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

if fleet_dispatch_requested "$@"; then
    exec bash "${SCRIPT_DIR}/fleet/run.sh" "$@"
else
    exec bash "${SCRIPT_DIR}/local/run.sh" "$@"
fi
