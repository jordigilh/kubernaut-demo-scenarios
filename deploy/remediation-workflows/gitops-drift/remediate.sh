#!/bin/sh
# GitOps Revert Remediation Script
#
# Authority: DD-WORKFLOW-003 (Parameterized Remediation Actions)
# Scenario: #125 -- GitOps drift remediation
#
# DD-WE-006: Git credentials are read from volume-mounted Secret (gitea-repo-creds),
# NOT embedded in GIT_REPO_URL by the LLM. The Secret is provisioned by operators
# in kubernaut-workflows and mounted at /run/kubernaut/secrets/gitea-repo-creds/.
#
# GIT_REPO_URL and GIT_BRANCH are discovered from the ArgoCD Application that
# targets TARGET_RESOURCE_NAMESPACE, not provided by the LLM.
#
# Parameters (env vars):
#   TARGET_RESOURCE_NAMESPACE      - Namespace of the affected workload
#   TARGET_RESOURCE_NAME  - Name of the affected resource
#
set -e

: "${TARGET_RESOURCE_NAMESPACE:?TARGET_RESOURCE_NAMESPACE is required}"
: "${TARGET_RESOURCE_NAME:?TARGET_RESOURCE_NAME is required}"

WORK_DIR="/tmp/gitops-revert"

SECRET_DIR="/run/kubernaut/secrets/gitea-repo-creds"
if [ ! -d "${SECRET_DIR}" ]; then
  echo "ERROR: Secret mount not found at ${SECRET_DIR}. Ensure gitea-repo-creds Secret exists in kubernaut-workflows."
  exit 1
fi
GIT_USERNAME=$(cat "${SECRET_DIR}/username")
GIT_PASSWORD=$(cat "${SECRET_DIR}/password")

echo "=== Phase 0: Discover ArgoCD Application ==="
ARGO_APP_JSON=$(kubectl get applications.argoproj.io --all-namespaces -o json)

GIT_REPO_URL=$(echo "${ARGO_APP_JSON}" | jq -r \
  --arg ns "${TARGET_RESOURCE_NAMESPACE}" \
  '.items[] | select(.spec.destination.namespace == $ns) | .spec.source.repoURL' \
  | head -1)

GIT_BRANCH_RAW=$(echo "${ARGO_APP_JSON}" | jq -r \
  --arg ns "${TARGET_RESOURCE_NAMESPACE}" \
  '.items[] | select(.spec.destination.namespace == $ns) | .spec.source.targetRevision' \
  | head -1)
GIT_BRANCH="${GIT_BRANCH_RAW}"
[ "${GIT_BRANCH}" = "HEAD" ] || [ -z "${GIT_BRANCH}" ] && GIT_BRANCH="main"

if [ -z "${GIT_REPO_URL}" ] || [ "${GIT_REPO_URL}" = "null" ]; then
  echo "ERROR: No ArgoCD Application found targeting namespace ${TARGET_RESOURCE_NAMESPACE}"
  exit 1
fi
echo "Discovered from ArgoCD: repoURL=${GIT_REPO_URL} branch=${GIT_BRANCH}"

echo "=== Phase 1: Validate ==="
echo "Skipping pod health validation: the target may be on a different cluster"
echo "Validated: GitOps application targets ${TARGET_RESOURCE_NAMESPACE}"

echo "=== Phase 2: Action ==="
AUTH_URL=$(echo "${GIT_REPO_URL}" | sed "s|://|://${GIT_USERNAME}:${GIT_PASSWORD}@|")
echo "Cloning repository: ${GIT_REPO_URL}"
rm -rf "${WORK_DIR}"
git clone --branch "${GIT_BRANCH}" --depth 5 "${AUTH_URL}" "${WORK_DIR}"
cd "${WORK_DIR}"

LAST_COMMIT=$(git log --oneline -1)
echo "Last commit: ${LAST_COMMIT}"

echo "Reverting last commit..."
git config user.email "kubernaut@kubernaut.ai"
git config user.name "Kubernaut Remediation"
git revert --no-edit HEAD

echo "Pushing revert..."
git push origin "${GIT_BRANCH}"

NEW_COMMIT=$(git rev-parse HEAD)
echo "Revert commit: ${NEW_COMMIT}"

echo "=== SUCCESS: Git commit reverted (${NEW_COMMIT}) ==="
echo "ArgoCD will sync the reverted state. RO/EM handle drift verification."
