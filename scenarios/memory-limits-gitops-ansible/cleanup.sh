#!/usr/bin/env bash
# Cleanup for Memory Limits GitOps (Ansible) Demo (#312)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

disable_prometheus_toolset || true

NAMESPACE="demo-memory-gitops-ansible"
GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="kubernaut"
GITEA_ADMIN_PASS="kubernaut123"
REPO_NAME="demo-memory-gitops-repo"

echo "==> Cleaning up Memory Limits GitOps (Ansible) demo..."

# ── Revert Gitea repo to healthy state ────────────────────────────────────────
if kubectl get namespace "${GITEA_NAMESPACE}" &>/dev/null; then
    echo "  Reverting Gitea repo to initial healthy state..."
    kill_stale_gitea_pf
    kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http "${GITEA_LOCAL_PORT}:3000" &>/dev/null &
    PF_PID=$!
    wait_for_port "${GITEA_LOCAL_PORT}"

    WORK_DIR=$(mktemp -d)
    if timeout 30 git clone "http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@localhost:${GITEA_LOCAL_PORT}/${GITEA_ADMIN_USER}/${REPO_NAME}.git" \
         "${WORK_DIR}/repo" &>/dev/null; then
        cd "${WORK_DIR}/repo"
        INITIAL_COMMIT=$(git rev-list --max-parents=0 HEAD 2>/dev/null || echo "")
        if [ -n "$INITIAL_COMMIT" ]; then
            CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
            if [ -n "$CURRENT_HEAD" ] && [ "$CURRENT_HEAD" != "$INITIAL_COMMIT" ]; then
                if git reset --hard "$INITIAL_COMMIT" &>/dev/null && \
                   git push --force origin main &>/dev/null; then
                    echo "  Repo reset to initial commit (${INITIAL_COMMIT:0:7})."
                else
                    echo "  WARNING: Failed to reset/push repo."
                fi
            else
                echo "  Repo already at initial commit."
            fi
        fi
        cd /
    else
        echo "  WARNING: Could not clone Gitea repo (timeout or unreachable)."
    fi
    rm -rf "${WORK_DIR}"
    kill "$PF_PID" 2>/dev/null || true
fi

# ── Delete stale RRs to prevent IneffectiveChain blocking ─────────────────────
for rr in $(kubectl get rr -n "${PLATFORM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
           | grep "=${NAMESPACE}$" | cut -d= -f1); do
    kubectl delete rr "$rr" -n "${PLATFORM_NS}" --wait=false 2>/dev/null || true
done

# ── Delete Kubernetes resources ──────────────────────────────────────────────
ARGOCD_NS=$(get_argocd_namespace)
kubectl delete application demo-memory-gitops-ansible -n "$ARGOCD_NS" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

echo "==> Cleanup complete."
echo "    Note: Gitea, ArgoCD, and AWX are left running for reuse by other scenarios."
