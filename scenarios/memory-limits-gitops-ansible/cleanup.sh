#!/usr/bin/env bash
# Cleanup for Memory Limits GitOps (Ansible) Demo (#312)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-memory-gitops-ansible"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up Memory Limits GitOps (Ansible) demo..."

ARGOCD_NS=$(get_argocd_namespace)
kubectl delete application demo-memory-gitops-ansible -n "${ARGOCD_NS}" --ignore-not-found 2>/dev/null || true

kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true

PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

echo "==> Cleaning up stale platform resources..."
kubectl delete remediationrequests --all -n "$PLATFORM_NS" --ignore-not-found 2>/dev/null || true
kubectl delete notificationrequests --all -n "$PLATFORM_NS" --ignore-not-found 2>/dev/null || true
kubectl delete remediationapprovalrequests --all -n "$PLATFORM_NS" --ignore-not-found 2>/dev/null || true

echo "==> Cleanup complete."
