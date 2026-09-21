#!/usr/bin/env bash
# Cleanup for GitOps Drift Demo -- Fleet (hub + spoke)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${GITOPS_NAMESPACE:-demo-webui}"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_connectivity

# ArgoCD, Gitea, and Kubernaut CRDs live on the hub.
export KUBECONFIG="${HUB_KUBECONFIG}"
# shellcheck source=../../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

ARGOCD_NS=$(get_argocd_namespace)
echo "==> [hub] Deleting GitOps Application..."
kubectl delete application web-frontend -n "${ARGOCD_NS}" --ignore-not-found

# A previous single-cluster run may have left the scenario namespace on the
# hub after its Application was deleted. Fleet mode owns this namespace too;
# remove that orphan so hub-side inspection cannot be mistaken for the active
# remote workload.
echo "==> [hub] Removing any stale local namespace ${NAMESPACE}..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true

echo "==> [hub] Deleting stale pipeline CRs for ${NAMESPACE}..."
for rr in $(kubectl get rr -n "${PLATFORM_NS}" \
  -o jsonpath='{range .items[*]}{.metadata.name}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
  | grep "=${NAMESPACE}$" | cut -d= -f1); do
  kubectl delete rr "$rr" -n "${PLATFORM_NS}" --wait=false 2>/dev/null || true
done

echo "==> [spoke] Deleting namespace ${NAMESPACE}..."
kubectl --kubeconfig="${SPOKE_KUBECONFIG}" delete namespace "${NAMESPACE}" \
  --ignore-not-found --wait=false

purge_pipeline_crds
echo "==> Fleet GitOps Drift cleanup complete. Gitea and ArgoCD were left running for reuse."
