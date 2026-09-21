#!/usr/bin/env bash
# Cleanup for CrashLoopBackOff Demo (#120)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_MODE=false
if [ -n "${HUB_KUBECONFIG:-}" ] || [ -n "${SPOKE_KUBECONFIG:-}" ]; then
  if [ -z "${HUB_KUBECONFIG:-}" ] || [ -z "${SPOKE_KUBECONFIG:-}" ]; then
    echo "ERROR: fleet cleanup requires both HUB_KUBECONFIG and SPOKE_KUBECONFIG." >&2
    exit 1
  fi
  FLEET_MODE=true
  export KUBECONFIG="${HUB_KUBECONFIG}"
  # shellcheck source=../../scripts/fleet-helper.sh
  source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
  fleet_check_connectivity
fi
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

namespace_exists() {
  if [ "$FLEET_MODE" = true ]; then
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get ns "$1"
  else
    kubectl get ns "$1"
  fi
}

disable_prometheus_toolset || true
restore_production_approval || true
restore_em || true

echo "==> Cleaning up CrashLoopBackOff demo..."

if [ "$FLEET_MODE" = true ]; then
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" delete prometheusrule \
      demo-app-alerts demo-app-alerts-checkout -n demo-checkout --ignore-not-found
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" delete prometheusrule \
      demo-app-alerts-checkout -n openshift-monitoring --ignore-not-found
elif [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-checkout -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
if [ "$FLEET_MODE" = true ]; then
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" delete namespace demo-checkout \
      --ignore-not-found --wait=true
else
    kubectl delete namespace demo-checkout --ignore-not-found --wait=true
fi

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
