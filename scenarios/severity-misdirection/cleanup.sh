#!/usr/bin/env bash
# Cleanup for Severity Misdirection Demo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Severity Misdirection demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule severity-misdirection-rules -n openshift-monitoring --ignore-not-found
else
    kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
fi
kubectl delete namespace demo-severity-misdirection --ignore-not-found --wait=true

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while kubectl get ns demo-severity-misdirection &>/dev/null; do
  sleep 2
  _elapsed=$((_elapsed + 2))
  if [ "$_elapsed" -ge 120 ]; then
    echo "  WARNING: Namespace demo-severity-misdirection still terminating after 120s, proceeding..."
    break
  fi
done

echo "==> Silencing stale alerts in AlertManager..."
silence_alert "ContainerOOMKilling" "demo-severity-misdirection" "2m"
silence_alert "KubePodCrashLooping" "demo-severity-misdirection" "2m"

purge_pipeline_crds

echo "==> Cleanup complete."
