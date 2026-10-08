#!/usr/bin/env bash
# External Actor Simulator -- Resource Contention Demo
#
# Watches for spec changes on the analytics-worker Deployment and reverts
# memory limits back to the original value (64Mi). Simulates a GitOps tool,
# another controller, or a human operator that conflicts with Kubernaut's
# remediation actions.
#
# The actor waits for the first RemediationRequest targeting this namespace
# to reach a terminal state (Completed/Failed/TimedOut) before it starts
# reverting. This ensures the first remediation cycle completes cleanly
# so the EM can assess effectiveness before the external drift occurs.
set -euo pipefail

NAMESPACE="demo-analytics"
DEPLOYMENT="analytics-worker"
ORIGINAL_LIMIT="64Mi"
ORIGINAL_REQUEST="32Mi"
PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

ACTOR_TIMEOUT=${ACTOR_TIMEOUT:-1800}

# In Fleet mode, RR state is on the hub while the workload is on the spoke.
# Keep local mode's ambient kubectl behavior unchanged.
if [ -n "${HUB_KUBECONFIG:-}" ] && [ -n "${SPOKE_KUBECONFIG:-}" ]; then
  kube_hub() { kubectl --kubeconfig="${HUB_KUBECONFIG}" "$@"; }
  kube_spoke() { kubectl --kubeconfig="${SPOKE_KUBECONFIG}" "$@"; }
else
  kube_hub() { kubectl "$@"; }
  kube_spoke() { kubectl "$@"; }
fi

echo "[external-actor] Watching ${DEPLOYMENT} in ${NAMESPACE} for spec changes... [timeout: ${ACTOR_TIMEOUT}s]"

_start=$SECONDS

echo "[external-actor] Waiting for first remediation cycle to complete..."
while [ $(( SECONDS - _start )) -lt "${ACTOR_TIMEOUT}" ]; do
  if ! kube_spoke get ns "${NAMESPACE}" &>/dev/null; then
    echo "[external-actor] Namespace ${NAMESPACE} gone. Exiting."
    exit 0
  fi

  PHASE=$(kube_hub get rr -n "${PLATFORM_NS}" \
    -l "kubernaut.ai/signal-namespace=${NAMESPACE}" \
    -o jsonpath='{.items[0].status.overallPhase}' 2>/dev/null || echo "")
  if [[ -z "$PHASE" ]]; then
    PHASE=$(kube_hub get rr -n "${PLATFORM_NS}" \
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

while [ $(( SECONDS - _start )) -lt "${ACTOR_TIMEOUT}" ]; do
  if ! kube_spoke get ns "${NAMESPACE}" &>/dev/null; then
    echo "[external-actor] Namespace ${NAMESPACE} gone. Exiting."
    exit 0
  fi

  CURRENT_LIMIT=$(kube_spoke -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "")

  if [[ -n "${CURRENT_LIMIT}" && "${CURRENT_LIMIT}" != "${ORIGINAL_LIMIT}" ]]; then
    echo "[external-actor] Detected spec change: memory limit ${CURRENT_LIMIT} != ${ORIGINAL_LIMIT}"
    echo "[external-actor] Reverting to original value (simulating GitOps sync)..."
    kube_spoke -n "${NAMESPACE}" patch deployment "${DEPLOYMENT}" --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/memory\",\"value\":\"${ORIGINAL_LIMIT}\"},{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/memory\",\"value\":\"${ORIGINAL_REQUEST}\"}]"
    echo "[external-actor] Reverted. Kubernaut's remediation is now ineffective."
  fi

  sleep 30
done

echo "[external-actor] Timeout (${ACTOR_TIMEOUT}s). Exiting."
