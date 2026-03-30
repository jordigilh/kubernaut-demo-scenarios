#!/usr/bin/env bash
# Deploy ArgoCD for GitOps demo scenarios.
#
# Platform-aware:
#   Kind  — full install (includes argocd-server for webhook-based sync)
#   OCP   — skips install (assumes OpenShift GitOps operator is present),
#           provisions Gitea credentials only
#
# Usage: ./scenarios/gitops/scripts/setup-argocd.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../../scripts/platform-helper.sh"

ARGOCD_NAMESPACE=$(get_argocd_namespace)

GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="kubernaut"
GITEA_ADMIN_PASS="kubernaut123"
REPO_NAME="demo-gitops-repo"

# ── ArgoCD installation (Kind only) ─────────────────────────────────────────

if [ "$PLATFORM" = "ocp" ]; then
    echo "==> OCP detected — skipping ArgoCD install (OpenShift GitOps operator expected)."
    if ! kubectl get namespace "${ARGOCD_NAMESPACE}" &>/dev/null; then
        echo "  ERROR: namespace '${ARGOCD_NAMESPACE}' not found."
        echo "  Install the OpenShift GitOps operator before running this script."
        exit 1
    fi
    echo "  Namespace '${ARGOCD_NAMESPACE}' exists."
else
    echo "==> Installing ArgoCD (full) in namespace ${ARGOCD_NAMESPACE}..."

    kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    kubectl apply -n "${ARGOCD_NAMESPACE}" --server-side --force-conflicts \
      -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    echo "==> Waiting for ArgoCD pods to be ready..."
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-application-controller \
      -n "${ARGOCD_NAMESPACE}" --timeout=300s
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-repo-server \
      -n "${ARGOCD_NAMESPACE}" --timeout=300s
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server \
      -n "${ARGOCD_NAMESPACE}" --timeout=300s

    echo "==> Ensuring default AppProject exists..."
    kubectl apply -f - <<APPPROJ
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: ${ARGOCD_NAMESPACE}
spec:
  description: Default project
  sourceRepos: ['*']
  destinations:
    - namespace: '*'
      server: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
APPPROJ
fi

# ── Gitea credentials (both platforms) ───────────────────────────────────────

echo "==> Configuring ArgoCD to trust Gitea repository..."
GITEA_REPO_URL="http://gitea-http.gitea:3000/kubernaut/demo-gitops-repo.git"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitea-repo-creds
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: http://gitea-http.gitea:3000
  username: kubernaut
  password: kubernaut123
EOF

echo "==> Provisioning Git credentials for workflow execution namespace (DD-WE-006)..."
kubectl create namespace kubernaut-workflows 2>/dev/null || true
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitea-repo-creds
  namespace: kubernaut-workflows
  labels:
    kubernaut.ai/dependency-type: git-credentials
stringData:
  username: kubernaut
  password: kubernaut123
EOF

# ── Gitea → ArgoCD webhook (Kind only) ───────────────────────────────────────
# OCP: OpenShift GitOps operator exposes argocd-server via Route; configure
#      the webhook manually or via the OpenShift GitOps console.

if [ "$PLATFORM" != "ocp" ]; then
    ARGOCD_WEBHOOK_URL="http://argocd-server.${ARGOCD_NAMESPACE}.svc.cluster.local/api/webhook"
    echo "==> Creating Gitea webhook → ArgoCD (${ARGOCD_WEBHOOK_URL})..."

    kill_stale_gitea_pf 2>/dev/null || true
    kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http "${GITEA_LOCAL_PORT}:3000" &>/dev/null &
    _WEBHOOK_PF_PID=$!
    wait_for_port "${GITEA_LOCAL_PORT}"

    GITEA_API="http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@localhost:${GITEA_LOCAL_PORT}"

    EXISTING_HOOKS=$(curl -sf "${GITEA_API}/api/v1/repos/${GITEA_ADMIN_USER}/${REPO_NAME}/hooks" 2>/dev/null || echo "[]")
    if echo "${EXISTING_HOOKS}" | grep -q "${ARGOCD_WEBHOOK_URL}"; then
        echo "  Webhook already exists, skipping."
    else
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
          -X POST "${GITEA_API}/api/v1/repos/${GITEA_ADMIN_USER}/${REPO_NAME}/hooks" \
          -H "Content-Type: application/json" \
          -d "{
            \"type\": \"gitea\",
            \"active\": true,
            \"config\": {
              \"url\": \"${ARGOCD_WEBHOOK_URL}\",
              \"content_type\": \"json\"
            },
            \"events\": [\"push\"]
          }" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "201" ]; then
            echo "  Webhook created successfully."
        else
            echo "  WARNING: Failed to create webhook (HTTP ${HTTP_CODE}). ArgoCD will fall back to polling."
        fi
    fi

    kill "$_WEBHOOK_PF_PID" 2>/dev/null || true
fi

echo "==> ArgoCD setup complete (platform: ${PLATFORM})"
echo "    Namespace: ${ARGOCD_NAMESPACE}"
echo "    Gitea repo registered: ${GITEA_REPO_URL}"
echo "    Git credentials provisioned in kubernaut-workflows (DD-WE-006)"
if [ "$PLATFORM" != "ocp" ]; then
    echo "    Gitea webhook → argocd-server: ${ARGOCD_WEBHOOK_URL:-N/A}"
fi
