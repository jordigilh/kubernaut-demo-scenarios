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

ARGO_APP=$(echo "${ARGO_APP_JSON}" | jq -c \
  --arg ns "${TARGET_RESOURCE_NAMESPACE}" \
  '[.items[] | select(.spec.destination.namespace == $ns)] | first // empty')

if [ -z "${ARGO_APP}" ]; then
  echo "ERROR: No ArgoCD Application found targeting namespace ${TARGET_RESOURCE_NAMESPACE}"
  exit 1
fi

GIT_REPO_URL=$(echo "${ARGO_APP}" | jq -r '.spec.source.repoURL // empty')
GIT_BRANCH_RAW=$(echo "${ARGO_APP}" | jq -r '.spec.source.targetRevision // empty')
SYNC_STATUS=$(echo "${ARGO_APP}" | jq -r '.status.sync.status // empty')
SYNC_REVISION=$(echo "${ARGO_APP}" | jq -r '.status.sync.revision // empty')

if [ -z "${GIT_REPO_URL}" ] || [ -z "${SYNC_REVISION}" ]; then
  echo "ERROR: ArgoCD Application has no repository URL or synchronized source revision"
  exit 1
fi
if [ "${SYNC_STATUS}" != "Synced" ]; then
  echo "ERROR: ArgoCD Application is not Synced (status=${SYNC_STATUS:-unknown}); refusing source rollback"
  exit 1
fi

# A branch is required for a safe push. A detached target revision can be
# inspected by ArgoCD but cannot safely receive the generated revert commit.
case "${GIT_BRANCH_RAW}" in
  ""|HEAD) GIT_BRANCH="main" ;;
  [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
    echo "ERROR: ArgoCD targetRevision is a detached commit (${GIT_BRANCH_RAW}); refusing to push a revert without a branch" >&2
    exit 1
    ;;
  *) GIT_BRANCH="${GIT_BRANCH_RAW}" ;;
esac

echo "Discovered from ArgoCD: repoURL=${GIT_REPO_URL} branch=${GIT_BRANCH} synchronized_revision=${SYNC_REVISION}"

echo "=== Phase 1: Validate ==="
echo "Skipping pod health validation: the target may be on a different cluster"
echo "Validated: GitOps application targets ${TARGET_RESOURCE_NAMESPACE} at synchronized revision ${SYNC_REVISION}"

echo "=== Phase 2: Action ==="
AUTH_URL=$(echo "${GIT_REPO_URL}" | sed "s|://|://${GIT_USERNAME}:${GIT_PASSWORD}@|")
echo "Cloning repository: ${GIT_REPO_URL}"
rm -rf "${WORK_DIR}"
git clone --branch "${GIT_BRANCH}" --depth 50 "${AUTH_URL}" "${WORK_DIR}"
cd "${WORK_DIR}"

CURRENT_HEAD=$(git rev-parse HEAD)
if [ "${CURRENT_HEAD}" != "${SYNC_REVISION}" ]; then
  echo "ERROR: repository branch ${GIT_BRANCH} advanced beyond ArgoCD synchronized revision ${SYNC_REVISION} (current=${CURRENT_HEAD}); refusing to revert an unrelated commit" >&2
  exit 1
fi

PARENT_LINE=$(git rev-list --parents -n 1 "${SYNC_REVISION}")
PARENT_COUNT=$(echo "${PARENT_LINE}" | awk '{print NF-1}')
MAINLINE_PARENT=$(echo "${PARENT_LINE}" | awk '{print $2}')
if [ "${PARENT_COUNT}" -lt 1 ] || [ -z "${MAINLINE_PARENT}" ]; then
  echo "ERROR: synchronized revision ${SYNC_REVISION} has no safe parent; refusing source rollback" >&2
  exit 1
fi

PARENT_WAS_SYNCED=$(echo "${ARGO_APP}" | jq -r \
  --arg parent "${MAINLINE_PARENT}" \
  '[.status.history[]?.revision] | index($parent) != null')
if [ "${PARENT_WAS_SYNCED}" != "true" ]; then
  echo "ERROR: first parent ${MAINLINE_PARENT} was not previously synchronized by ArgoCD; refusing source rollback" >&2
  exit 1
fi

LAST_COMMIT=$(git log --oneline -1 "${SYNC_REVISION}")
echo "Synchronized commit: ${LAST_COMMIT}"
echo "Previously synchronized first parent: ${MAINLINE_PARENT}"

echo "Reverting synchronized source revision..."
git config user.email "kubernaut@kubernaut.ai"
git config user.name "Kubernaut Remediation"
if [ "${PARENT_COUNT}" -gt 1 ]; then
  echo "Merge commit detected; reverting against first-parent mainline ${MAINLINE_PARENT}"
  git revert --no-edit --mainline 1 "${SYNC_REVISION}"
else
  git revert --no-edit "${SYNC_REVISION}"
fi

echo "Pushing revert..."
git push origin "${GIT_BRANCH}"

NEW_COMMIT=$(git rev-parse HEAD)
echo "Revert commit: ${NEW_COMMIT}"

echo "=== SUCCESS: Git commit reverted (${NEW_COMMIT}) ==="
echo "ArgoCD will sync the reverted state. RO/EM handle drift verification."
