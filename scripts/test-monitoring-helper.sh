#!/usr/bin/env bash
# Offline contract checks for demo Metrics API readiness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/monitoring-helper.sh"
SETUP="${SCRIPT_DIR}/setup-demo-cluster.sh"
SPOKE="${SCRIPT_DIR}/../scenarios/operator-oomkill-informer/fleet/spoke.sh"
AMTOOL_HELPER="${SCRIPT_DIR}/amtool-helper.sh"

grep -Fq 'wait_for_metrics_api' "${HELPER}"
grep -Fq 'kubectl top nodes --no-headers' "${HELPER}"
grep -Fq 'v1beta1.metrics.k8s.io' "${HELPER}"
grep -Fq 'get endpointslice -n kube-system' "${HELPER}"
grep -Fq 'rollout restart' "${HELPER}"
grep -Fq 'app.kubernetes.io/name=metrics-server' "${HELPER}"
grep -Fq 'ensure_metrics_server' "${SETUP}"
grep -Fq 'wait_for_metrics_api 120' "${SPOKE}"
grep -Fq 'amtool_prepare_connection' "${AMTOOL_HELPER}"
grep -Fq 'http.config.file' "${AMTOOL_HELPER}"
if grep -Fq 'kubectl annotate namespace' "${SCRIPT_DIR}/../scenarios/operator-oomkill-informer/local/run.sh" && \
    grep -A1 -Fq -- '--ignore-not-found' "${SCRIPT_DIR}/../scenarios/operator-oomkill-informer/local/run.sh"; then
    echo "FAIL: local operator scenario passes unsupported --ignore-not-found to kubectl annotate" >&2
    exit 1
fi

for caller in \
    "${SCRIPT_DIR}/monitoring-helper.sh" \
    "${SCRIPT_DIR}/validation-helper.sh" \
    "${SCRIPT_DIR}/platform-helper.sh" \
    "${SCRIPT_DIR}/record-scenario.sh" \
    "${SCRIPT_DIR}/show-alert.sh" \
    "${SCRIPT_DIR}/../scenarios/crashloop/record.sh"; do
    if grep -Fq 'alertmanager.url=http://localhost:9093' "${caller}"; then
        echo "FAIL: ${caller} still hardcodes an HTTP Alertmanager URL" >&2
        exit 1
    fi
done

bash -n "${AMTOOL_HELPER}" "${HELPER}" "${SETUP}" "${SPOKE}" \
    "${SCRIPT_DIR}/validation-helper.sh" "${SCRIPT_DIR}/platform-helper.sh" \
    "${SCRIPT_DIR}/record-scenario.sh" "${SCRIPT_DIR}/show-alert.sh" \
    "${SCRIPT_DIR}/../scenarios/crashloop/record.sh"
echo "PASS: demo setup requires Metrics API/kubectl top readiness and TLS-capable Alertmanager polling"
