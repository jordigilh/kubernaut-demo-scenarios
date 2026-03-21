#!/usr/bin/env bash
# Cleanup for Memory Escalation Demo (#168)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Memory Escalation demo..."

# Revert HAPI Prometheus toolset opt-in (#108).
echo "==> Disabling HolmesGPT Prometheus toolset..."
helm upgrade kubernaut "${CHART_REF}" \
  -n "${PLATFORM_NS}" --reuse-values \
  --set holmesgptApi.prometheus.enabled=false \
  --wait --timeout 3m

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace demo-memory-escalation --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-memory-escalation &>/dev/null; do
  sleep 2
done

restart_alertmanager

echo "==> Cleanup complete."
