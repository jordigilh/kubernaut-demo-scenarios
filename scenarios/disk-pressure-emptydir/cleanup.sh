#!/usr/bin/env bash
# Cleanup for DiskPressure emptyDir Migration Demo (#324)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-diskpressure"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up DiskPressure emptyDir demo..."

echo "==> Disabling HolmesGPT Prometheus toolset..."
disable_prometheus_toolset || true

# Delete ArgoCD Application first (stops sync loop).
# The app lives in openshift-gitops on OCP, argocd on Kind.
ARGOCD_NS=$(get_argocd_namespace)
kubectl delete application demo-diskpressure -n "${ARGOCD_NS}" --ignore-not-found 2>/dev/null || true

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

# Unmount the constrained filesystem from the worker node (both Kind and OCP)
_unmount_cmds='
    systemctl stop kubelet
    cp -a /var/lib/kubelet /tmp/kubelet-restore
    umount /var/lib/kubelet
    rm -f /tmp/nodefs-constrained.img
    cp -a /tmp/kubelet-restore/. /var/lib/kubelet/ 2>/dev/null || true
    rm -rf /tmp/kubelet-restore
    systemctl start kubelet
'
for node in $(kubectl get nodes -l scenario=disk-pressure \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    if [ "${PLATFORM:-kind}" = "ocp" ]; then
        if oc debug "node/${node}" -- chroot /host bash -c \
          "mount | grep '/var/lib/kubelet.*loop'" &>/dev/null; then
            echo "  Unmounting constrained filesystem on ${node} (via oc debug)..."
            oc debug "node/${node}" -- chroot /host bash -c "$_unmount_cmds" 2>/dev/null \
              || echo "  WARNING: could not unmount constrained FS on ${node}"
        fi
    else
        local_runtime="podman"
        if ! command -v podman &>/dev/null; then local_runtime="docker"; fi
        if "${local_runtime}" exec "${node}" mount 2>/dev/null | grep -q '/var/lib/kubelet.*loop'; then
            echo "  Unmounting constrained filesystem on ${node}..."
            "${local_runtime}" exec "${node}" bash -c "$_unmount_cmds" 2>/dev/null \
              || echo "  WARNING: could not unmount constrained FS on ${node}"
        fi
    fi
done

# Remove scenario label/taint and Kubernaut labels from tagged nodes
for node in $(kubectl get nodes -l scenario=disk-pressure \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    echo "  Removing scenario label/taint from node: ${node}"
    kubectl label node "$node" scenario- 2>/dev/null || true
    kubectl taint node "$node" scenario=disk-pressure:NoSchedule- 2>/dev/null || true
done
for node in $(kubectl get nodes -l kubernaut.ai/managed=true \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    echo "  Removing Kubernaut labels from node: ${node}"
    kubectl label node "$node" \
        kubernaut.ai/managed- \
        kubernaut.ai/environment- \
        kubernaut.ai/business-unit- \
        kubernaut.ai/service-owner- \
        kubernaut.ai/criticality- \
        kubernaut.ai/sla-tier- 2>/dev/null || true
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
