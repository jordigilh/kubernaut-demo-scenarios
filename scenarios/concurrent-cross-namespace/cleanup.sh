#!/usr/bin/env bash
# Cleanup for Concurrent Cross-Namespace Demo (#172)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Concurrent Cross-Namespace demo..."

for NS in demo-team-alpha demo-team-beta; do
  kubectl delete -f "${SCRIPT_DIR}/manifests/${NS#demo-}/prometheus-rule.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete namespace "${NS}" --ignore-not-found --wait=false
done

echo "==> Waiting for namespace deletion to complete..."
for NS in demo-team-alpha demo-team-beta; do
  while kubectl get ns "${NS}" &>/dev/null; do
    sleep 2
  done
done

restart_alertmanager

echo "==> Cleanup complete."
