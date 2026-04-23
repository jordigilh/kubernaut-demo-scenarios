#!/usr/bin/env bash
# Cleanup for HPA Maxed Out Demo (#123)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up HPA Maxed Out demo..."

echo "==> Disabling Kubernaut Agent Prometheus toolset..."
disable_prometheus_toolset || true

# Kill any CPU stress processes running inside pods
for pod in $(kubectl get pods -n demo-hpa -l app=api-frontend -o name 2>/dev/null); do
    kubectl exec -n demo-hpa "$pod" -- killall yes 2>/dev/null || true
done

# Delete pipeline CRDs targeting this namespace
for rr in $(kubectl get remediationrequests -n "${PLATFORM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null | grep demo-hpa | cut -f1); do
    kubectl delete remediationrequest "$rr" -n "${PLATFORM_NS}" --ignore-not-found 2>/dev/null || true
done

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace demo-hpa --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-hpa &>/dev/null; do
    sleep 2
done

# Restart AlertManager to clear stale notification state
restart_alertmanager

purge_pipeline_crds

echo "==> Cleanup complete."
