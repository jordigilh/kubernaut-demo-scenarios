#!/usr/bin/env bash
# Cleanup for Resource Quota Exhaustion Demo (#171)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Resource Quota Exhaustion demo..."

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

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace demo-quota --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-quota &>/dev/null; do
  sleep 2
done

# Restart AlertManager so stale alert groups (repeat_interval=1h) don't
# suppress the fresh webhook notification for the new deployment.
restart_alertmanager

echo "==> Cleanup complete."
