#!/usr/bin/env bash
# Offline contract checks for demo Metrics API readiness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/monitoring-helper.sh"
SETUP="${SCRIPT_DIR}/setup-demo-cluster.sh"
SPOKE="${SCRIPT_DIR}/../scenarios/operator-oomkill-informer/fleet/spoke.sh"
AMTOOL_HELPER="${SCRIPT_DIR}/amtool-helper.sh"
PROM_HELPER="${SCRIPT_DIR}/prometheus-helper.sh"

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
grep -Fq '_prometheus_run_with_timeout' "${PROM_HELPER}"
grep -Fq 'https' "${PROM_HELPER}"
grep -Fq 'http.config.file' "${HELPER}"
grep -Fq 'prometheus_api_get "$ns" "$pod" "/api/v1/rules?type=alert"' "${HELPER}"
grep -Fq 'https://127.0.0.1' "${SCRIPT_DIR}/run-scenario.sh"
grep -Fq 'SINGLE_CLUSTER_GITOPS=true' "${SCRIPT_DIR}/../scenarios/operator-oomkill-informer/local/run.sh"
grep -Fq 'SINGLE_CLUSTER_GITOPS' "${SCRIPT_DIR}/../scenarios/operator-oomkill-informer/fleet/hub.sh"
grep -Fq 'GITOPS_MODE=true' "${SCRIPT_DIR}/../scenarios/operator-oomkill-informer/local/run.sh"
grep -Fq 'GITOPS_MODE' "${SCRIPT_DIR}/../scenarios/operator-oomkill-informer/validate.sh"
grep -Fq 'amtool_prepare_connection' "${SCRIPT_DIR}/fleet-helper.sh"
if grep -Fq 'wget -qO- http://localhost:9093/api/v2/alerts' "${SCRIPT_DIR}/fleet-helper.sh"; then
    echo "FAIL: fleet Alertmanager polling still hardcodes HTTP" >&2
    exit 1
fi
if grep -Fq 'http://localhost:9090/api/v1/query' "${HELPER}" || \
    grep -Fq 'promtool query instant http://localhost:9090' "${HELPER}"; then
    echo "FAIL: Prometheus helper still hardcodes an HTTP-only endpoint" >&2
    exit 1
fi
if grep -Fq 'HUB_KUBECONFIG=' "${SCRIPT_DIR}/../scenarios/operator-oomkill-informer/local/run.sh" || \
    grep -Fq 'SPOKE_KUBECONFIG=' "${SCRIPT_DIR}/../scenarios/operator-oomkill-informer/local/run.sh"; then
    echo "FAIL: single-cluster operator OOM entrypoint invents hub/spoke kubeconfigs" >&2
    exit 1
fi
if grep -R -Fq 'OPERATOR_GITOPS_LOCAL_DIRECT' "${SCRIPT_DIR}/../scenarios/operator-oomkill-informer" --include='*.sh'; then
    echo "FAIL: operator OOM scenario still selects an infrastructure-specific direct workflow" >&2
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
echo "PASS: demo setup requires Metrics API/kubectl top readiness and TLS-capable Alertmanager polling"
