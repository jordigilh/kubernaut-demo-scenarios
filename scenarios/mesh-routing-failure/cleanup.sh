#!/usr/bin/env bash
# Cleanup for Istio Mesh Routing Failure Demo (#136)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Istio Mesh Routing Failure demo..."

kubectl delete -f "${SCRIPT_DIR}/manifests/deny-policy.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/istio-podmonitor.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/deployment.yaml" --ignore-not-found
kubectl delete namespace demo-mesh-failure --ignore-not-found

echo "==> Cleanup complete."
echo "    NOTE: Istio itself is NOT removed."
