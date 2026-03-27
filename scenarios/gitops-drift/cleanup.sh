#!/usr/bin/env bash
# Cleanup for GitOps Drift Demo (#125)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

NAMESPACE="demo-gitops"
GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="kubernaut"
GITEA_ADMIN_PASS="kubernaut123"
REPO_NAME="demo-gitops-repo"

echo "==> Cleaning up GitOps Drift demo..."

# ── Revert Gitea repo to healthy state (#236) ────────────────────────────────
# The inject phase pushes a broken commit. If remediation didn't git-revert it
# (or didn't run at all), subsequent runs see "nothing to commit" and hang.
if kubectl get namespace "${GITEA_NAMESPACE}" &>/dev/null; then
    echo "  Reverting Gitea repo to initial healthy state..."
    kill_stale_gitea_pf
    kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http "${GITEA_LOCAL_PORT}:3000" &>/dev/null &
    PF_PID=$!
    sleep 3

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

# ── Delete stale RRs to prevent IneffectiveChain blocking (#238) ─────────────
for rr in $(kubectl get rr -n "${PLATFORM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}={.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
           | grep "=${NAMESPACE}$" | cut -d= -f1); do
    kubectl delete rr "$rr" -n "${PLATFORM_NS}" --wait=false 2>/dev/null || true
done

# ── Delete Kubernetes resources ──────────────────────────────────────────────
kubectl delete -f "${SCRIPT_DIR}/manifests/argocd-application.yaml" --ignore-not-found
kubectl delete namespace "${NAMESPACE}" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found

echo "==> Cleanup complete."
echo "    Note: Gitea and ArgoCD are left running for reuse by other scenarios."
echo "    To remove them: kubectl delete namespace gitea argocd"
