#!/usr/bin/env bash
# Node NotReady Demo -- Automated Runner
# Scenario #127: Node failure -> cordon + drain
#
# Prerequisites:
#   - Kind cluster with worker node (kubernaut.ai/managed=true)
#   - Prometheus with kube-state-metrics
#   - Podman (to pause/unpause Kind node container)
#
# Usage: ./scenarios/node-notready/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-node"

APPROVE_MODE="--auto-approve"
SKIP_VALIDATE=""
for _arg in "$@"; do
    case "$_arg" in
        --auto-approve)  APPROVE_MODE="--auto-approve" ;;
        --interactive)   APPROVE_MODE="--interactive" ;;
        --no-validate)   SKIP_VALIDATE=true ;;
    esac
done

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
require_demo_ready

# Workaround for #282: clean up completed WFE Jobs to avoid name collisions
# when the same workflow+target is reused across runs.
kubectl delete jobs -n kubernaut-workflows -l kubernaut.ai/component=workflowexecution --field-selector=status.successful=1 --ignore-not-found 2>/dev/null || true
kubectl delete jobs -n kubernaut-workflows --field-selector=status.successful=1 --ignore-not-found 2>/dev/null || true

echo "============================================="
echo " Node NotReady Demo (#127)"
echo "============================================="
echo ""

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for healthy deployment
echo "==> Step 2: Waiting for web-service to be ready..."
kubectl wait --for=condition=Available deployment/web-service \
  -n "${NAMESPACE}" --timeout=120s
echo "  web-service is running (3 replicas)."
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""

# Step 3: Label the target node so the Gateway accepts NodeNotReady signals
WORKER_NODE=$(kubectl get nodes -l 'kubernaut.ai/managed=true,!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$WORKER_NODE" ]; then
    echo "==> Step 3: Labeling target node ${WORKER_NODE} for signal acceptance..."
    kubectl label node "$WORKER_NODE" \
        kubernaut.ai/environment=production \
        kubernaut.ai/business-unit=infrastructure \
        kubernaut.ai/service-owner=infra-team \
        kubernaut.ai/criticality=critical \
        kubernaut.ai/sla-tier=tier-1 \
        --overwrite
fi

# Step 4: Simulate node failure
echo "==> Step 4: Simulating node failure via podman pause..."
bash "${SCRIPT_DIR}/inject-node-failure.sh"
echo ""

# Step 5: Wait for alert
echo "==> Step 5: Waiting for NodeNotReady alert to fire (~1-2 min)..."
echo "  Check: kubectl get nodes -w"
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""

# Step 6: Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi

# Step 7: Silence alert to prevent new RRs while the node remains NotReady.
# The cordon+drain remediation doesn't restore the node (that's cleanup's job),
# so the KubeNodeNotReady alert stays active and the Gateway will keep creating
# legitimate RRs until the node is unpaused.
echo ""
echo "==> Step 7: Silencing KubeNodeNotReady alert (10m) to prevent post-remediation RRs..."
silence_alert "KubeNodeNotReady" "${NAMESPACE}" "10m"
