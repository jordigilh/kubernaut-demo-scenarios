#!/usr/bin/env bash
# Cleanup for SLO Error Budget Burn Demo (#128)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up SLO Error Budget Burn demo..."

# Revert HAPI Prometheus toolset opt-in (#108).
echo "==> Disabling HolmesGPT Prometheus toolset..."
helm upgrade kubernaut "${CHART_REF}" \
  -n "${PLATFORM_NS}" --reuse-values \
  --set holmesgptApi.prometheus.enabled=false \
  --wait --timeout 3m

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace demo-slo --ignore-not-found

echo "==> Cleanup complete."
