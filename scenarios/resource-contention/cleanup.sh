#!/usr/bin/env bash
# Cleanup for Resource Contention Demo (#231)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

NAMESPACE="demo-resource-contention"
PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

echo "==> Cleaning up Resource Contention demo..."

echo "==> Purging pipeline CRDs targeting ${NAMESPACE}..."
for kind in remediationrequests signalprocessings aianalyses workflowexecutions effectivenessassessments; do
  for name in $(kubectl get "$kind" -n "$PLATFORM_NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null | grep "$NAMESPACE" | cut -f1); do
    kubectl delete "$kind" "$name" -n "$PLATFORM_NS" --wait=false 2>/dev/null || true
  done
done

kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns "$NAMESPACE" &>/dev/null; do
  sleep 2
done

restart_alertmanager

echo "==> Cleanup complete."
