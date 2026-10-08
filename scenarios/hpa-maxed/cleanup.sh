#!/usr/bin/env bash
# Cleanup for HPA Maxed Out Demo (#123)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
if fleet_initialize_targeting "$@"; then
    # Kill workload stress on the spoke, while targeted RR deletion,
    # Alertmanager, toolset, and pipeline cleanup remain on the hub.
    # shellcheck source=../../scripts/platform-helper.sh
    source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
    disable_prometheus_toolset || true
    for pod in $(fleet_target_kubectl get pods -n demo-gateway -l app=api-frontend -o name 2>/dev/null); do
        fleet_target_kubectl exec -n demo-gateway "$pod" -- /bin/sh -c 'for f in /proc/*/comm; do [ "$(cat $f 2>/dev/null)" = "yes" ] && kill $(echo $f|cut -d/ -f3) 2>/dev/null; done; true' 2>/dev/null || true
    done
    for rr in $(kubectl get remediationrequests -n "${PLATFORM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null | grep demo-gateway | cut -f1); do
        kubectl delete remediationrequest "$rr" -n "${PLATFORM_NS}" --ignore-not-found 2>/dev/null || true
    done
    fleet_cleanup_scenario_resources "${SCRIPT_DIR}/manifests" demo-gateway
    restart_alertmanager
    purge_pipeline_crds
    exit 0
fi
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up HPA Maxed Out demo..."

echo "==> Disabling Kubernaut Agent Prometheus toolset..."
disable_prometheus_toolset || true

# Kill any CPU stress processes running inside pods
for pod in $(kubectl get pods -n demo-gateway -l app=api-frontend -o name 2>/dev/null); do
    kubectl exec -n demo-gateway "$pod" -- /bin/sh -c 'for f in /proc/*/comm; do [ "$(cat $f 2>/dev/null)" = "yes" ] && kill $(echo $f|cut -d/ -f3) 2>/dev/null; done; true' 2>/dev/null || true
done

# Delete pipeline CRDs targeting this namespace
for rr in $(kubectl get remediationrequests -n "${PLATFORM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null | grep demo-gateway | cut -f1); do
    kubectl delete remediationrequest "$rr" -n "${PLATFORM_NS}" --ignore-not-found 2>/dev/null || true
done

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-gateway -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-gateway --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while kubectl get ns demo-gateway &>/dev/null; do
    sleep 2
    _elapsed=$((_elapsed + 2))
    if [ "$_elapsed" -ge 120 ]; then
        echo "  WARNING: Namespace demo-gateway still terminating after 120s, proceeding..."
        break
    fi
done

# Restart AlertManager to clear stale notification state
restart_alertmanager

purge_pipeline_crds

echo "==> Cleanup complete."
