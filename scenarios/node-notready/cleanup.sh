#!/usr/bin/env bash
# Cleanup for Node NotReady Demo (#127)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

if [ "$PLATFORM" = "ocp" ]; then
    echo "ERROR: node-notready cleanup is Kind-only (uses podman unpause)."
    echo "       See https://github.com/jordigilh/kubernaut-demo-scenarios/issues/287"
    exit 1
fi

echo "==> Cleaning up Node NotReady demo..."

# Restore the paused worker node
WORKER_NODE=$(kubectl get nodes -l 'kubernaut.ai/managed=true,!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$WORKER_NODE" ]; then
  echo "  Unpausing worker node: $WORKER_NODE"
  podman unpause "$WORKER_NODE" 2>/dev/null || true
  echo "  Uncordoning worker node: $WORKER_NODE"
  kubectl uncordon "$WORKER_NODE" 2>/dev/null || true
fi

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-app-alerts-compute -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-compute --ignore-not-found

# Remove Kubernaut signal labels from the target node
if [ -n "$WORKER_NODE" ]; then
    echo "  Removing Kubernaut labels from node: ${WORKER_NODE}"
    kubectl label node "$WORKER_NODE" \
        kubernaut.ai/environment- \
        kubernaut.ai/business-unit- \
        kubernaut.ai/service-owner- \
        kubernaut.ai/criticality- \
        kubernaut.ai/sla-tier- 2>/dev/null || true
fi

# Restore original policy.rego from annotation saved by run.sh
ORIGINAL_B64=$(kubectl get configmap signalprocessing-policy -n "${PLATFORM_NS}" \
  -o jsonpath='{.metadata.annotations.kubernaut\.ai/original-policy-rego}' 2>/dev/null || echo "")
if [ -n "${ORIGINAL_B64}" ]; then
  echo "  Restoring original SP policy.rego..."
  ORIGINAL_POLICY=$(echo "${ORIGINAL_B64}" | base64 -d)
  kubectl patch configmap signalprocessing-policy -n "${PLATFORM_NS}" --type=merge \
    -p "{\"data\":{\"policy.rego\":$(echo "${ORIGINAL_POLICY}" | jq -Rs .)}}"
  kubectl annotate configmap signalprocessing-policy -n "${PLATFORM_NS}" \
    "kubernaut.ai/original-policy-rego-" 2>/dev/null || true
  kubectl rollout restart deployment/signalprocessing-controller -n "${PLATFORM_NS}" 2>/dev/null || true
fi

purge_pipeline_crds

echo "==> Cleanup complete."
