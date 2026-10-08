#!/usr/bin/env bash
# Cleanup for CrashLoopBackOff Demo (#120)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-checkout"
# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
if fleet_initialize_targeting "$@"; then
  # Workload and monitoring resources are spoke-side. Controller restoration,
  # Alertmanager, and pipeline cleanup stay on the hub.
  # shellcheck source=../../scripts/platform-helper.sh
  source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
  disable_prometheus_toolset || true
  restore_production_approval || true
  restore_em || true
  fleet_cleanup_scenario_resources "${SCRIPT_DIR}/manifests" "$NAMESPACE"
  PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"
  kubectl get configmap remediationorchestrator-config -n "$PLATFORM_NS" -o yaml \
    | sed 's/stabilizationWindow: "[^"]*"/stabilizationWindow: "60s"/' \
    | kubectl apply -f - >/dev/null 2>&1
  kubectl rollout restart deploy/remediationorchestrator-controller -n "$PLATFORM_NS" >/dev/null 2>&1
  kubectl rollout status deploy/remediationorchestrator-controller -n "$PLATFORM_NS" --timeout=120s >/dev/null 2>&1
  purge_pipeline_crds
  restart_alertmanager
  exit 0
fi
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

namespace_exists() {
  kubectl get ns "$1"
}

disable_prometheus_toolset || true
restore_production_approval || true
restore_em || true

echo "==> Cleaning up CrashLoopBackOff demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-checkout -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-checkout --ignore-not-found --wait=true

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
while namespace_exists demo-checkout &>/dev/null; do
  sleep 2
  _elapsed=$((_elapsed + 2))
  if [ "$_elapsed" -ge 120 ]; then
    echo "  WARNING: Namespace demo-checkout still terminating after 120s, proceeding..."
    break
  fi
done

# Restart AlertManager so stale alert groups (repeat_interval=1h) don't
# suppress the fresh webhook notification for the new deployment.
restart_alertmanager

echo "==> Cleanup complete."
