#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

disable_prometheus_toolset || true
restore_production_approval || true

echo "==> Cleaning up SCC violation demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-agents --ignore-not-found --wait=true

PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

echo "==> Restoring stabilizationWindow to 60s..."
kubectl get configmap remediationorchestrator-config -n "$PLATFORM_NS" -o yaml \
  | sed 's/stabilizationWindow: "[^"]*"/stabilizationWindow: "60s"/' \
  | kubectl apply -f - >/dev/null 2>&1
kubectl rollout restart deploy/remediationorchestrator-controller -n "$PLATFORM_NS" >/dev/null 2>&1
kubectl rollout status deploy/remediationorchestrator-controller -n "$PLATFORM_NS" --timeout=120s >/dev/null 2>&1
purge_pipeline_crds

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while kubectl get ns demo-agents &>/dev/null; do
  sleep 2
  _elapsed=$((_elapsed + 2))
  if [ "$_elapsed" -ge 120 ]; then
    echo "  WARNING: Namespace demo-agents still terminating after 120s, proceeding..."
    break
  fi
done

restart_alertmanager

echo "==> Cleanup complete."
