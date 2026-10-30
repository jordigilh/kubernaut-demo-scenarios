#!/usr/bin/env bash
# Offline contract checks for demo Metrics API readiness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/monitoring-helper.sh"
SETUP="${SCRIPT_DIR}/setup-demo-cluster.sh"
SPOKE="${SCRIPT_DIR}/../scenarios/operator-oomkill-informer/fleet/spoke.sh"
AMTOOL_HELPER="${SCRIPT_DIR}/amtool-helper.sh"
PROM_HELPER="${SCRIPT_DIR}/prometheus-helper.sh"
PROM_TEST="${SCRIPT_DIR}/test-prometheus-helper.sh"

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
grep -Fq 'prometheus_prepare_connection' "${PROM_HELPER}"
grep -Fq 'prometheus_api_get' "${PROM_HELPER}"
grep -Fq 'PROMETHEUS_SCHEME' "${PROM_HELPER}"
grep -Fq 'https' "${PROM_HELPER}"
grep -Fq 'http.config.file' "${HELPER}"
grep -Fq 'https://127.0.0.1' "${SCRIPT_DIR}/run-scenario.sh"

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

for shell_script in \
    "${AMTOOL_HELPER}" \
    "${PROM_HELPER}" \
    "${HELPER}" \
    "${SETUP}" \
    "${SPOKE}" \
    "${SCRIPT_DIR}/run-scenario.sh" \
    "${SCRIPT_DIR}/validation-helper.sh" \
    "${SCRIPT_DIR}/platform-helper.sh" \
    "${SCRIPT_DIR}/record-scenario.sh" \
    "${SCRIPT_DIR}/show-alert.sh" \
    "${SCRIPT_DIR}/../scenarios/crashloop/record.sh"; do
    bash -n "${shell_script}"
done
bash "${PROM_TEST}"
echo "PASS: demo setup requires Metrics API/kubectl top readiness and protocol-aware Prometheus/Alertmanager polling"
