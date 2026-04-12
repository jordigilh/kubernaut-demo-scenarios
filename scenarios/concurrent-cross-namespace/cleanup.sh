#!/usr/bin/env bash
# Cleanup for Concurrent Cross-Namespace Demo (#172)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

disable_prometheus_toolset || true

echo "==> Cleaning up Concurrent Cross-Namespace demo..."

# Remove scenario-specific workflow CRDs and RBAC (including stale restart-pods-v1)
for _wf in hotfix-config-v1 restart-pods-v1 crashloop-rollback-risk-v1; do
  kubectl delete remediationworkflow "$_wf" -n "${PLATFORM_NS}" --ignore-not-found 2>/dev/null || true
  kubectl delete clusterrolebinding "${_wf}-runner" --ignore-not-found 2>/dev/null || true
  kubectl delete clusterrole "${_wf}-runner" --ignore-not-found 2>/dev/null || true
  kubectl delete serviceaccount "${_wf}-runner" -n "${WE_NAMESPACE:-kubernaut-workflows}" --ignore-not-found 2>/dev/null || true
done

for NS in demo-team-alpha demo-team-beta; do
  kubectl delete -f "${SCRIPT_DIR}/manifests/${NS#demo-}/prometheus-rule.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false
done

echo "==> Waiting for namespace deletion to complete..."
for NS in demo-team-alpha demo-team-beta; do
  _elapsed=0
  while kubectl get ns "${NS}" &>/dev/null; do
    sleep 2
    _elapsed=$((_elapsed + 2))
    if [ "$_elapsed" -ge 120 ]; then
      echo "  WARNING: Namespace ${NS} still terminating after 120s, proceeding..."
      break
    fi
  done
done

# Restore original policy.rego from annotation saved by run.sh
ORIGINAL_B64=$(kubectl get configmap signalprocessing-policy -n "${PLATFORM_NS}" \
  -o jsonpath='{.metadata.annotations.kubernaut\.ai/original-policy-rego}' 2>/dev/null || echo "")
if [ -n "${ORIGINAL_B64}" ]; then
  ORIGINAL_POLICY=$(echo "${ORIGINAL_B64}" | base64 -d)
  kubectl patch configmap signalprocessing-policy -n "${PLATFORM_NS}" --type=merge \
    -p "{\"data\":{\"policy.rego\":$(echo "${ORIGINAL_POLICY}" | jq -Rs .)}}"
  kubectl annotate configmap signalprocessing-policy -n "${PLATFORM_NS}" \
    "kubernaut.ai/original-policy-rego-" 2>/dev/null || true
fi
kubectl rollout restart deployment/signalprocessing-controller -n "${PLATFORM_NS}" 2>/dev/null || true

restart_alertmanager

echo "==> Cleanup complete."
