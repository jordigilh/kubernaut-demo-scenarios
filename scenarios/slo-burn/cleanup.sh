#!/usr/bin/env bash
# Cleanup for SLO Error Budget Burn Demo (#128)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Cleaning up SLO Error Budget Burn demo..."

# Revert HAPI Prometheus toolset opt-in (#108). Runs in a subshell so that
# a sourcing or Helm failure cannot abort the resource cleanup below.
(
  # shellcheck source=../../scripts/platform-helper.sh
  source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
  echo "==> Disabling HolmesGPT Prometheus toolset..."
  helm upgrade kubernaut "${CHART_REF}" \
    -n "${PLATFORM_NS}" --reuse-values \
    --set holmesgptApi.prometheus.enabled=false \
    --wait --timeout 3m
) 2>/dev/null || echo "  WARNING: could not disable HAPI Prometheus toolset. Run manually: helm upgrade kubernaut <chart> -n kubernaut-system --reuse-values --set holmesgptApi.prometheus.enabled=false"

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace demo-slo --ignore-not-found

echo "==> Cleanup complete."
