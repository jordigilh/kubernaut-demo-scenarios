#!/usr/bin/env bash
# Generate sustained CPU load on api-frontend pods to push HPA to maxReplicas.
# Uses kubectl exec to run CPU-intensive processes inside the existing containers,
# keeping the cluster free of load-generator pods (avoids LLM detecting artificial
# load during AIAnalysis).
#
# The CPU burn runs in the background inside each pod and survives after this
# script exits. cleanup.sh kills the stress processes.
set -euo pipefail

NAMESPACE="demo-hpa"
LABEL_SELECTOR="app=api-frontend"

_stress_pods() {
    local pods
    pods=$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_SELECTOR}" \
        -o jsonpath='{.items[*].metadata.name}')

    if [ -z "$pods" ]; then
        echo "ERROR: No pods found with label ${LABEL_SELECTOR} in ${NAMESPACE}"
        return 1
    fi

    for pod in $pods; do
        if ! kubectl exec -n "${NAMESPACE}" "${pod}" -- pgrep yes </dev/null >/dev/null 2>&1; then
            echo "  Stressing pod ${pod}..."
            kubectl exec -n "${NAMESPACE}" "${pod}" -- sh -c \
                'for i in 1 2 3; do yes > /dev/null 2>&1 & done; exit 0' \
                </dev/null >/dev/null 2>&1
        fi
    done
}

echo "==> Starting CPU stress on api-frontend pods..."
_stress_pods

# When HPA scales up, new pods won't have stress. Wait and re-stress.
echo "==> Waiting 30s for HPA to scale, then stressing any new pods..."
sleep 30
_stress_pods

echo "==> All pods under CPU stress."
echo "    Watch HPA: kubectl get hpa -n ${NAMESPACE} -w"
echo "    Once currentReplicas == maxReplicas (3), the alert will fire after 2 min."

ORIGINAL_MAX=${ORIGINAL_MAX:-3}

_kill_stress() {
    echo "==> Killing CPU stress on all api-frontend pods..."
    local _kill_cmd='for f in /proc/*/comm; do [ "$(cat $f 2>/dev/null)" = "yes" ] && kill $(echo $f|cut -d/ -f3) 2>/dev/null; done; true'
    for pod in $(kubectl get pods -n "${NAMESPACE}" -l "${LABEL_SELECTOR}" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        kubectl exec -n "${NAMESPACE}" "${pod}" -- /bin/sh -c "$_kill_cmd" 2>/dev/null || true
    done
}

WATCH_TIMEOUT=${WATCH_TIMEOUT:-1800}
echo "==> Watching HPA for scale-up beyond original maxReplicas (${ORIGINAL_MAX}) [timeout: ${WATCH_TIMEOUT}s]..."
_start=$SECONDS
while [ $(( SECONDS - _start )) -lt "${WATCH_TIMEOUT}" ]; do
    if ! kubectl get ns "${NAMESPACE}" &>/dev/null; then
        echo "==> Namespace ${NAMESPACE} no longer exists. Aborting watch."
        exit 1
    fi

    current=$(kubectl get hpa api-frontend -n "${NAMESPACE}" \
        -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo "0")
    max=$(kubectl get hpa api-frontend -n "${NAMESPACE}" \
        -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || echo "${ORIGINAL_MAX}")

    if [ "${max}" -gt "${ORIGINAL_MAX}" ] && [ "${current}" -gt "${ORIGINAL_MAX}" ]; then
        echo "==> HPA scaled to ${current} replicas (maxReplicas patched to ${max}). Remediation detected."
        echo "==> Stress kept running until EA phase kills it (validate.sh ON_VERIFYING_HOOK)."
        exit 0
    fi
    sleep 10
done

echo "==> TIMEOUT: HPA did not scale beyond maxReplicas=${ORIGINAL_MAX} within ${WATCH_TIMEOUT}s."
_kill_stress
exit 1
