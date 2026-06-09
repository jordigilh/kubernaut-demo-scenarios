#!/usr/bin/env bash
# Cleanup for VM Boot Failure Demo (#376)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

disable_prometheus_toolset || true
restore_production_approval || true

echo "==> Cleaning up VM Boot Failure demo..."

# Restore original SP policy if we injected KubeVirt rules
PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"
EXISTING_B64=$(kubectl get configmap signalprocessing-policy -n "${PLATFORM_NS}" \
  -o jsonpath='{.metadata.annotations.kubernaut\.ai/original-policy-rego}' 2>/dev/null || echo "")
if [ -n "${EXISTING_B64}" ]; then
    echo "  Restoring original SP policy.rego..."
    ORIGINAL_POLICY=$(echo "${EXISTING_B64}" | base64 -d)
    kubectl patch configmap signalprocessing-policy -n "${PLATFORM_NS}" --type=merge \
      -p "{\"data\":{\"policy.rego\":$(echo "${ORIGINAL_POLICY}" | jq -Rs .)}}"
    kubectl annotate configmap signalprocessing-policy -n "${PLATFORM_NS}" \
      "kubernaut.ai/original-policy-rego-" 2>/dev/null || true
fi

kubectl delete vm legacy-app-vm -n demo-vm-boot --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete datavolume legacy-app-rootdisk -n demo-vm-boot --ignore-not-found --wait=false 2>/dev/null || true

kubectl delete namespace demo-vm-boot --ignore-not-found --wait=true

purge_pipeline_crds

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while kubectl get ns demo-vm-boot &>/dev/null; do
    sleep 2
    _elapsed=$((_elapsed + 2))
    if [ "$_elapsed" -ge 120 ]; then
        echo "  WARNING: Namespace demo-vm-boot still terminating after 120s, proceeding..."
        break
    fi
done

restart_alertmanager

echo "==> Cleanup complete."
