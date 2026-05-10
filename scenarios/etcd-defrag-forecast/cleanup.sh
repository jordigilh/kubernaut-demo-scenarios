#!/usr/bin/env bash
# Cleanup for etcd Defrag Forecast Demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up etcd Defrag Forecast demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule etcd-defrag-rules -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-etcd-defrag --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns demo-etcd-defrag &>/dev/null; do
    sleep 2
done

echo "==> Silencing stale alerts in AlertManager..."
silence_alert "EtcdHighFragmentationRatio" "demo-etcd-defrag" "2m"

purge_pipeline_crds

echo "==> Cleanup complete."
