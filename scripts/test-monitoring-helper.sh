#!/usr/bin/env bash
# Offline contract checks for demo Metrics API readiness.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/monitoring-helper.sh"
SETUP="${SCRIPT_DIR}/setup-demo-cluster.sh"
SPOKE="${SCRIPT_DIR}/../scenarios/operator-oomkill-informer/fleet/spoke.sh"

grep -Fq 'wait_for_metrics_api' "${HELPER}"
grep -Fq 'kubectl top nodes --no-headers' "${HELPER}"
grep -Fq 'v1beta1.metrics.k8s.io' "${HELPER}"
grep -Fq 'get endpointslice -n kube-system' "${HELPER}"
grep -Fq 'rollout restart' "${HELPER}"
grep -Fq 'app.kubernetes.io/name=metrics-server' "${HELPER}"
grep -Fq 'ensure_metrics_server' "${SETUP}"
grep -Fq 'wait_for_metrics_api 120' "${SPOKE}"

bash -n "${HELPER}" "${SETUP}" "${SPOKE}"
echo "PASS: demo setup requires Metrics API and kubectl top readiness with bounded recovery"
