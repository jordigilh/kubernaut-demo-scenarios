#!/usr/bin/env bash
# Cleanup for Resource Contention Demo (#231)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

NAMESPACE="demo-resource-contention"
PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

echo "==> Cleaning up Resource Contention demo..."

# Revert HAPI Prometheus toolset opt-in (#108). Non-fatal so resource
# cleanup always proceeds even if Helm is unavailable.
echo "==> Disabling HolmesGPT Prometheus toolset..."
if ! helm upgrade kubernaut "${CHART_REF}" \
  -n "${PLATFORM_NS}" --reuse-values \
  --set holmesgptApi.prometheus.enabled=false \
  --wait --timeout 3m 2>/dev/null; then
    echo "  WARNING: could not disable HAPI Prometheus toolset."
    echo "  Run manually: helm upgrade kubernaut <chart> -n kubernaut-system --reuse-values --set holmesgptApi.prometheus.enabled=false"
fi

echo "==> Purging pipeline CRDs targeting ${NAMESPACE}..."
for kind in remediationrequests signalprocessings aianalyses workflowexecutions effectivenessassessments; do
  for name in $(kubectl get "$kind" -n "$PLATFORM_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null | grep "$NAMESPACE" | cut -f1); do
    kubectl delete "$kind" "$name" -n "$PLATFORM_NS" --wait=false 2>/dev/null || true
  done
done

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns "$NAMESPACE" &>/dev/null; do
  sleep 2
done

restart_alertmanager

echo "==> Cleanup complete."
