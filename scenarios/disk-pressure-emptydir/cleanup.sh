#!/usr/bin/env bash
# Cleanup for DiskPressure emptyDir Migration Demo (#324)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-diskpressure"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up DiskPressure emptyDir demo..."

# Delete ArgoCD Application first (stops sync loop)
kubectl delete -f "${SCRIPT_DIR}/manifests/argocd-application.yaml" --ignore-not-found 2>/dev/null || true

# Delete PrometheusRule
kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found 2>/dev/null || true

# Delete temp backup/restore Jobs and PVC if still present
kubectl delete job postgres-backup postgres-backup-verify postgres-restore \
  -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
kubectl delete pvc postgres-emergency-backup \
  -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

# Delete namespace
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=true

PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

# Uncordon all nodes (safety net)
for node in $(kubectl get nodes -o jsonpath='{range .items[?(@.spec.unschedulable)]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    echo "  Uncordoning node: ${node}"
    kubectl uncordon "${node}" 2>/dev/null || true
done

echo "==> Cleaning up stale platform resources..."
kubectl delete remediationrequests --all -n "$PLATFORM_NS" --ignore-not-found 2>/dev/null || true
kubectl delete notificationrequests --all -n "$PLATFORM_NS" --ignore-not-found 2>/dev/null || true
kubectl delete aianalyses --all -n "$PLATFORM_NS" --ignore-not-found 2>/dev/null || true
kubectl delete remediationapprovalrequests --all -n "$PLATFORM_NS" --ignore-not-found 2>/dev/null || true
kubectl delete workflowexecutions --all -n "$PLATFORM_NS" --ignore-not-found 2>/dev/null || true

echo "==> Waiting for namespace deletion to complete..."
while kubectl get ns "${NAMESPACE}" &>/dev/null; do
  sleep 2
done

restart_alertmanager

# Clean up Gitea repo (optional -- leave for reuse)
# GITEA_NAMESPACE="gitea"
# kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http 3000:3000 &
# PF_PID=$!; sleep 2
# curl -s -X DELETE "http://localhost:3000/api/v1/repos/kubernaut/demo-diskpressure-repo" \
#   -u "kubernaut:kubernaut123" -o /dev/null 2>/dev/null || true
# kill "${PF_PID}" 2>/dev/null || true

echo "==> Cleanup complete."
