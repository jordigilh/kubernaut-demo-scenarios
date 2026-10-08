#!/usr/bin/env bash
# Operator OOMKill from Informer Cache Flooding -- Fleet Spoke Steps
# Based on kubeflow/spark-operator#2878.
#
# Prepares only the spoke. The operator, RBAC, namespace, and monitoring
# resources are applied by the hub's Argo CD Application; the fault stimulus
# is injected by fleet/hub.sh after that Application is healthy. This keeps
# the desired state GitOps-managed end to end.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-controllers"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

if ! kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get apiservice v1beta1.metrics.k8s.io \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q True; then
    echo "ERROR: Kubernetes Metrics API is unavailable on the spoke. Install metrics-server so workload CPU/memory can be inspected with kubectl top." >&2
    exit 1
fi

echo "==> [spoke=${SPOKE_KUBECONFIG}] Preparing kube-state-metrics for Argo CD..."
fleet_ensure_kube_state_metrics
echo "  Spoke is ready for the hub-side Argo CD Application."
