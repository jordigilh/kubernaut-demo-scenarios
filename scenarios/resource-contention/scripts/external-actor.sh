#!/usr/bin/env bash
# External Actor Simulator -- Resource Contention Demo
#
# Watches for spec changes on the contention-app Deployment and reverts
# memory limits back to the original value (64Mi). Simulates a GitOps tool,
# another controller, or a human operator that conflicts with Kubernaut's
# remediation actions.
#
# The actor waits for the first RemediationRequest targeting this namespace
# to reach a terminal state (Completed/Failed/TimedOut) before it starts
# reverting. This ensures the first remediation cycle completes cleanly
# so the EM can assess effectiveness before the external drift occurs.
set -euo pipefail

NAMESPACE="demo-resource-contention"
DEPLOYMENT="contention-app"
ORIGINAL_LIMIT="64Mi"
ORIGINAL_REQUEST="32Mi"
PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

echo "[external-actor] Watching ${DEPLOYMENT} in ${NAMESPACE} for spec changes..."

# Wait for the first RR to reach a terminal state before reverting.
echo "[external-actor] Waiting for first remediation cycle to complete..."
while true; do
  PHASE=$(kubectl get rr -n "${PLATFORM_NS}" \
    -l "kubernaut.ai/signal-namespace=${NAMESPACE}" \
    -o jsonpath='{.items[0].status.overallPhase}' 2>/dev/null || echo "")
  if [[ -z "$PHASE" ]]; then
    # No label selector support — fall back to jsonpath filter
    PHASE=$(kubectl get rr -n "${PLATFORM_NS}" \
      -o jsonpath='{range .items[?(@.spec.signalLabels.namespace=="'"${NAMESPACE}"'")]}{.status.overallPhase}{"\n"}{end}' 2>/dev/null | head -1 || echo "")
  fi
  case "$PHASE" in
    Completed|Failed|TimedOut|Cancelled|Skipped)
      echo "[external-actor] First RR reached terminal phase (${PHASE}). Starting revert loop."
      break
      ;;
  esac
  sleep 10
done

while true; do
  CURRENT_LIMIT=$(kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "")

  if [[ -n "${CURRENT_LIMIT}" && "${CURRENT_LIMIT}" != "${ORIGINAL_LIMIT}" ]]; then
    echo "[external-actor] Detected spec change: memory limit ${CURRENT_LIMIT} != ${ORIGINAL_LIMIT}"
    echo "[external-actor] Reverting to original value (simulating GitOps sync)..."
    kubectl -n "${NAMESPACE}" patch deployment "${DEPLOYMENT}" --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/memory\",\"value\":\"${ORIGINAL_LIMIT}\"},{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/memory\",\"value\":\"${ORIGINAL_REQUEST}\"}]"
    echo "[external-actor] Reverted. Kubernaut's remediation is now ineffective."
  fi

  sleep 30
done
