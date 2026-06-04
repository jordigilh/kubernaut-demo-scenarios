#!/usr/bin/env bash
# Cleanup for Istio Mesh Routing Failure Demo (#136)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Istio Mesh Routing Failure demo..."

kubectl delete -f "${SCRIPT_DIR}/manifests/deny-policy.yaml" --ignore-not-found
if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete -f "${SCRIPT_DIR}/manifests/istio-podmonitor.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/deployment.yaml" --ignore-not-found
kubectl delete namespace demo-mesh --ignore-not-found

purge_pipeline_crds

echo "==> Cleanup complete."
echo "    NOTE: Istio itself is NOT removed."
