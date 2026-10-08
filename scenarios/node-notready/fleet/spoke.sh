#!/usr/bin/env bash
# Node NotReady Demo -- Fleet Spoke Steps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-compute"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

if [ "$(detect_spoke_platform)" != "kind" ]; then
    echo "ERROR: node-notready Fleet mode is Kind-only (the fault injector pauses a Podman node)." >&2
    exit 1
fi
if ! kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get apiservice v1beta1.metrics.k8s.io \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q True; then
    echo "ERROR: metrics-server is unavailable on the spoke; node-notready RCA requires the Metrics API." >&2
    exit 1
fi

WORKER_NODE=$(kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get nodes \
    -l 'kubernaut.ai/managed=true,!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "${WORKER_NODE}" ]; then
    echo "ERROR: node-notready Fleet mode needs a non-control-plane managed worker on the spoke." >&2
    exit 1
fi

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${MANIFEST_DIR}"
kubectl_workload wait --for=condition=Available deployment/web-service \
    -n "${NAMESPACE}" --timeout=120s

echo "==> [spoke] Labelling ${WORKER_NODE} for NodeNotReady signal acceptance..."
kubectl --kubeconfig="${SPOKE_KUBECONFIG}" label node "${WORKER_NODE}" \
    kubernaut.ai/environment=production \
    kubernaut.ai/business-unit=infrastructure \
    kubernaut.ai/service-owner=infra-team \
    kubernaut.ai/criticality=critical \
    kubernaut.ai/sla-tier=tier-1 --overwrite

# SignalProcessing runs on the hub, but cluster-scoped Node signals have an
# empty namespace. Install the same scenario policy fragment against the hub.
HUB_NS="${PLATFORM_NS:-kubernaut-system}"
EXISTING_B64=$(kubectl --kubeconfig="${HUB_KUBECONFIG}" get configmap signalprocessing-policy \
    -n "${HUB_NS}" -o jsonpath='{.metadata.annotations.kubernaut\.ai/original-policy-rego}' 2>/dev/null || true)
if [ -n "${EXISTING_B64}" ]; then
    ORIGINAL_POLICY=$(printf '%s' "${EXISTING_B64}" | base64 -d)
else
    ORIGINAL_POLICY=$(kubectl --kubeconfig="${HUB_KUBECONFIG}" get configmap signalprocessing-policy \
        -n "${HUB_NS}" -o jsonpath='{.data.policy\.rego}')
fi
kubectl --kubeconfig="${HUB_KUBECONFIG}" annotate configmap signalprocessing-policy -n "${HUB_NS}" \
    "kubernaut.ai/original-policy-rego=$(printf '%s' "${ORIGINAL_POLICY}" | base64)" --overwrite >/dev/null
NODE_ENV_RULES=$(grep -v -E '^(package |import )' "${SCRIPT_DIR}/rego/node-environment.rego")
MERGED_POLICY="${ORIGINAL_POLICY}

${NODE_ENV_RULES}"
kubectl --kubeconfig="${HUB_KUBECONFIG}" patch configmap signalprocessing-policy -n "${HUB_NS}" \
    --type=merge -p "{\"data\":{\"policy.rego\":$(printf '%s' "${MERGED_POLICY}" | jq -Rs .)}}" >/dev/null
kubectl --kubeconfig="${HUB_KUBECONFIG}" rollout restart deployment/signalprocessing-controller -n "${HUB_NS}" >/dev/null
kubectl --kubeconfig="${HUB_KUBECONFIG}" rollout status deployment/signalprocessing-controller \
    -n "${HUB_NS}" --timeout=180s >/dev/null

echo "==> [spoke] Pausing ${WORKER_NODE} to trigger KubeNodeNotReady..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-node-failure.sh"
