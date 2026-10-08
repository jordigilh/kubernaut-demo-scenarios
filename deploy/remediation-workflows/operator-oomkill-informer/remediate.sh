#!/bin/sh
# GitOps forward-change workflow for operator-oomkill-informer (#446).
#
# The workflow runs on the hub, where the read-only gitea-repo-creds Secret is
# mounted. It discovers the Argo CD Application from the hub API, edits the
# desired-state Deployment in a new branch, opens a pull request, and waits for
# the pull request to be merged by a human. It does not merge, push main, or
# patch a live Kubernetes resource.

set -eu

: "${TARGET_RESOURCE_NAMESPACE:?TARGET_RESOURCE_NAMESPACE is required}"
: "${TARGET_RESOURCE_NAME:?TARGET_RESOURCE_NAME is required}"
: "${TARGET_RESOURCE_KIND:?TARGET_RESOURCE_KIND is required}"

if [ "${TARGET_RESOURCE_KIND}" != "Deployment" ]; then
    echo "ERROR: GitOps memory workflow only supports Deployment targets (got ${TARGET_RESOURCE_KIND})." >&2
    exit 1
fi

SECRET_DIR="/run/kubernaut/secrets/gitea-repo-creds"
if [ ! -r "${SECRET_DIR}/username" ] || [ ! -r "${SECRET_DIR}/password" ]; then
    echo "ERROR: read-only gitea-repo-creds mount is missing at ${SECRET_DIR}." >&2
    exit 1
fi

GIT_USERNAME=$(cat "${SECRET_DIR}/username")
GIT_PASSWORD=$(cat "${SECRET_DIR}/password")
export GIT_USERNAME GIT_PASSWORD

WORK_DIR="${WORK_DIR:-/tmp/operator-oomkill-gitops}"
PR_WAIT_TIMEOUT_SECONDS="${PR_WAIT_TIMEOUT_SECONDS:-1500}"
PR_POLL_INTERVAL_SECONDS="${PR_POLL_INTERVAL_SECONDS:-10}"
GITOPS_DEPLOYMENT_FILE="${GITOPS_DEPLOYMENT_FILE:-deployment.yaml}"
# The workflow is intentionally RR-agnostic. Every invocation applies one
# fixed forward change; remediation history and platform routing decide whether
# another invocation is appropriate.
MEMORY_INCREASE_MIB=128

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

case "${PR_WAIT_TIMEOUT_SECONDS}" in
    ''|*[!0-9]*) fail "PR_WAIT_TIMEOUT_SECONDS must be a positive integer" ;;
esac
case "${PR_POLL_INTERVAL_SECONDS}" in
    ''|*[!0-9]*) fail "PR_POLL_INTERVAL_SECONDS must be a positive integer" ;;
esac
[ "${PR_WAIT_TIMEOUT_SECONDS}" -gt 0 ] || fail "PR_WAIT_TIMEOUT_SECONDS must be greater than zero"
[ "${PR_POLL_INTERVAL_SECONDS}" -gt 0 ] || fail "PR_POLL_INTERVAL_SECONDS must be greater than zero"

case "${GITOPS_DEPLOYMENT_FILE}" in
    ''|/*|../*|*/../*|*//*|*[!a-zA-Z0-9._/-]*)
        fail "GITOPS_DEPLOYMENT_FILE must be a relative repository path without traversal: ${GITOPS_DEPLOYMENT_FILE}"
        ;;
esac

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "=== Phase 0: Discover Argo CD Application on the execution hub ==="
APPLICATIONS_JSON=$(kubectl get applications.argoproj.io --all-namespaces -o json) \
    || fail "unable to list Argo CD Applications on the hub"

APPLICATION_COUNT=$(printf '%s' "${APPLICATIONS_JSON}" | jq -r --arg ns "${TARGET_RESOURCE_NAMESPACE}" \
    '[.items[] | select(.spec.destination.namespace == $ns)] | length')
[ "${APPLICATION_COUNT}" = "1" ] \
    || fail "expected exactly one Argo CD Application targeting namespace ${TARGET_RESOURCE_NAMESPACE}, found ${APPLICATION_COUNT}"

APPLICATION_ROW=$(printf '%s' "${APPLICATIONS_JSON}" | jq -r --arg ns "${TARGET_RESOURCE_NAMESPACE}" \
    '.items[] | select(.spec.destination.namespace == $ns) |
     [.metadata.name, .metadata.namespace, .spec.source.repoURL,
      .spec.source.targetRevision, (.spec.source.path // ".")] | @tsv')

APPLICATION_NAME=$(printf '%s' "${APPLICATION_ROW}" | cut -f1)
APPLICATION_NAMESPACE=$(printf '%s' "${APPLICATION_ROW}" | cut -f2)
GIT_REPO_URL=$(printf '%s' "${APPLICATION_ROW}" | cut -f3)
GIT_BRANCH=$(printf '%s' "${APPLICATION_ROW}" | cut -f4)
APPLICATION_PATH=$(printf '%s' "${APPLICATION_ROW}" | cut -f5)

[ -n "${GIT_REPO_URL}" ] || fail "Argo CD Application ${APPLICATION_NAME} has no repository URL"
[ -n "${GIT_BRANCH}" ] && [ "${GIT_BRANCH}" != "HEAD" ] || GIT_BRANCH="main"
[ -n "${APPLICATION_PATH}" ] || APPLICATION_PATH="."

case "${GIT_REPO_URL}" in
    http://*|https://*) ;;
    *) fail "unsupported repository URL scheme in Argo CD Application: ${GIT_REPO_URL}" ;;
esac

# The Application is the source of truth for this run, but repository URLs are
# still untrusted input from the Kubernetes API. Refuse embedded credentials,
# query/fragment suffixes, and nested repository paths so the API endpoint and
# clone target cannot silently diverge.
GIT_AUTHORITY=$(printf '%s\n' "${GIT_REPO_URL}" | sed -E 's#^https?://([^/]+).*#\1#')
case "${GIT_AUTHORITY}" in
    *'@'*) fail "repository URL must not contain embedded credentials" ;;
esac
case "${GIT_REPO_URL}" in
    *\?*|*\#*) fail "repository URL must not contain a query or fragment" ;;
esac

GIT_BASE_URL=$(printf '%s\n' "${GIT_REPO_URL}" | sed -E 's#^(https?://[^/]+).*#\1#')
REPO_PATH=$(printf '%s\n' "${GIT_REPO_URL}" | sed -E 's#^https?://[^/]+/##; s#\.git$##')
GIT_OWNER=${REPO_PATH%%/*}
GIT_REPOSITORY=${REPO_PATH#*/}
case "${REPO_PATH}" in
    ""|/*|*/|*//*|*/*/*) fail "could not parse owner/repository from ${GIT_REPO_URL}" ;;
esac
[ -n "${GIT_OWNER}" ] && [ "${GIT_REPOSITORY}" != "${REPO_PATH}" ] \
    || fail "could not parse owner/repository from ${GIT_REPO_URL}"

GITEA_API_BASE="${GIT_BASE_URL}/api/v1"
echo "  Application: ${APPLICATION_NAMESPACE}/${APPLICATION_NAME}"
echo "  Repository:  ${GIT_REPO_URL}"
echo "  Branch/path: ${GIT_BRANCH}/${APPLICATION_PATH}"

echo "=== Phase 1: Clone and validate desired state ==="

# A temporary credential helper keeps credentials out of the repository URL,
# which is stored by Git in .git/config and may be shown in diagnostics.
GIT_CREDENTIAL_HELPER="${WORK_DIR}/git-credential-helper"
cat > "${GIT_CREDENTIAL_HELPER}" <<'CREDENTIAL_HELPER'
#!/bin/sh
if [ "${1:-}" = "get" ]; then
    printf 'username=%s\n' "${GIT_USERNAME}"
    printf 'password=%s\n' "${GIT_PASSWORD}"
fi
CREDENTIAL_HELPER
chmod 700 "${GIT_CREDENTIAL_HELPER}"

REPOSITORY_DIR="${WORK_DIR}/repo"
git -c "credential.helper=${GIT_CREDENTIAL_HELPER}" clone \
    --branch "${GIT_BRANCH}" --depth 50 "${GIT_REPO_URL}" "${REPOSITORY_DIR}" \
    || fail "unable to clone ${GIT_REPO_URL} branch ${GIT_BRANCH}"

SAFE_TARGET=$(printf '%s' "${TARGET_RESOURCE_NAME}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
PR_BRANCH="kubernaut/operator-memory-${SAFE_TARGET}-$(date -u +%Y%m%d%H%M%S)-$$"
git -C "${REPOSITORY_DIR}" checkout -b "${PR_BRANCH}" >/dev/null

APPLICATION_ROOT="${REPOSITORY_DIR}/${APPLICATION_PATH}"
[ -d "${APPLICATION_ROOT}" ] || fail "Argo CD source path does not exist in the repository: ${APPLICATION_PATH}"

DEPLOYMENT_FILE="${APPLICATION_ROOT}/${GITOPS_DEPLOYMENT_FILE}"
if [ ! -f "${DEPLOYMENT_FILE}" ]; then
    DEPLOYMENT_FILE=""
    MANIFEST_FILE_LIST="${WORK_DIR}/manifest-files.txt"
    find "${APPLICATION_ROOT}" -type f \( -name '*.yaml' -o -name '*.yml' \) \
        -print > "${MANIFEST_FILE_LIST}"
    while IFS= read -r candidate; do
        [ -n "${candidate}" ] || continue
        if awk -v target_name="${TARGET_RESOURCE_NAME}" -v target_ns="${TARGET_RESOURCE_NAMESPACE}" '
            function reset() { kind=""; name=""; ns=""; in_metadata=0 }
            BEGIN { reset() }
            /^---[[:space:]]*$/ { reset(); next }
            /^kind:[[:space:]]*/ { kind=$0; sub(/^kind:[[:space:]]*/, "", kind) }
            /^metadata:[[:space:]]*$/ { in_metadata=1; next }
            /^spec:[[:space:]]*$/ { in_metadata=0 }
            in_metadata && /^  name:[[:space:]]*/ {
                name=$0; sub(/^  name:[[:space:]]*/, "", name); gsub(/"/, "", name)
            }
            in_metadata && /^  namespace:[[:space:]]*/ {
                ns=$0; sub(/^  namespace:[[:space:]]*/, "", ns); gsub(/"/, "", ns)
            }
            END { exit !(kind == "Deployment" && name == target_name && ns == target_ns) }
        ' "${candidate}"; then
            DEPLOYMENT_FILE="${candidate}"
            break
        fi
    done < "${MANIFEST_FILE_LIST}"
fi

# An Argo CD Kustomize overlay commonly lives in a different directory from
# the base Deployment it references (for example, overlays/ocp -> manifests).
# If the configured relative path and the overlay subtree did not identify the
# target, resolve the exact Deployment anywhere in this repository. The target
# name and namespace must still identify one file, preventing an arbitrary
# manifest from being edited.
if [ -z "${DEPLOYMENT_FILE}" ]; then
    MANIFEST_FILE_LIST="${WORK_DIR}/repository-manifest-files.txt"
    find "${REPOSITORY_DIR}" -path "${REPOSITORY_DIR}/.git" -prune -o \
        -type f \( -name '*.yaml' -o -name '*.yml' \) -print > "${MANIFEST_FILE_LIST}"
    MATCH_LIST="${WORK_DIR}/deployment-matches.txt"
    : > "${MATCH_LIST}"
    while IFS= read -r candidate; do
        [ -n "${candidate}" ] || continue
        if awk -v target_name="${TARGET_RESOURCE_NAME}" -v target_ns="${TARGET_RESOURCE_NAMESPACE}" '
            function reset() { kind=""; name=""; ns=""; in_metadata=0 }
            BEGIN { reset() }
            /^---[[:space:]]*$/ { reset(); next }
            /^kind:[[:space:]]*/ { kind=$0; sub(/^kind:[[:space:]]*/, "", kind) }
            /^metadata:[[:space:]]*$/ { in_metadata=1; next }
            /^spec:[[:space:]]*$/ { in_metadata=0 }
            in_metadata && /^  name:[[:space:]]*/ {
                name=$0; sub(/^  name:[[:space:]]*/, "", name); gsub(/"/, "", name)
            }
            in_metadata && /^  namespace:[[:space:]]*/ {
                ns=$0; sub(/^  namespace:[[:space:]]*/, "", ns); gsub(/"/, "", ns)
            }
            END { exit !(kind == "Deployment" && name == target_name && ns == target_ns) }
        ' "${candidate}"; then
            printf '%s\n' "${candidate}" >> "${MATCH_LIST}"
        fi
    done < "${MANIFEST_FILE_LIST}"
    MATCH_COUNT=$(wc -l < "${MATCH_LIST}" | tr -d ' ')
    if [ "${MATCH_COUNT}" = "1" ]; then
        DEPLOYMENT_FILE=$(cat "${MATCH_LIST}")
    elif [ "${MATCH_COUNT}" -gt 1 ]; then
        fail "found multiple desired-state files for Deployment/${TARGET_RESOURCE_NAMESPACE}/${TARGET_RESOURCE_NAME}: $(tr '\n' ' ' < "${MATCH_LIST}")"
    fi
fi
[ -n "${DEPLOYMENT_FILE}" ] && [ -f "${DEPLOYMENT_FILE}" ] \
    || fail "could not locate Deployment/${TARGET_RESOURCE_NAME} in the Argo CD source tree"

CURRENT_MEM=$(awk -v target_name="${TARGET_RESOURCE_NAME}" -v target_ns="${TARGET_RESOURCE_NAMESPACE}" '
    function reset() { kind=""; name=""; ns=""; in_metadata=0; in_limits=0 }
    BEGIN { reset() }
    /^---[[:space:]]*$/ { reset(); next }
    /^kind:[[:space:]]*/ { kind=$0; sub(/^kind:[[:space:]]*/, "", kind) }
    /^metadata:[[:space:]]*$/ { in_metadata=1; next }
    /^spec:[[:space:]]*$/ { in_metadata=0 }
    in_metadata && /^  name:[[:space:]]*/ {
        name=$0; sub(/^  name:[[:space:]]*/, "", name); gsub(/"/, "", name)
    }
    in_metadata && /^  namespace:[[:space:]]*/ {
        ns=$0; sub(/^  namespace:[[:space:]]*/, "", ns); gsub(/"/, "", ns)
    }
    kind == "Deployment" && name == target_name && ns == target_ns &&
        /^[[:space:]]+limits:[[:space:]]*$/ { in_limits=1; next }
    in_limits && /^[[:space:]]+memory:[[:space:]]*/ {
        value=$0; sub(/^[[:space:]]+memory:[[:space:]]*/, "", value)
        gsub(/"/, "", value); print value; exit
    }
' "${DEPLOYMENT_FILE}" | sed 's/[[:space:]]//g')

[ -n "${CURRENT_MEM}" ] || fail "Deployment/${TARGET_RESOURCE_NAME} has no memory limit in ${DEPLOYMENT_FILE}"

case "${CURRENT_MEM}" in
    *Mi) CURRENT_MIB=${CURRENT_MEM%Mi} ;;
    *Gi) CURRENT_MIB=$((${CURRENT_MEM%Gi} * 1024)) ;;
    *) fail "unsupported memory quantity ${CURRENT_MEM}; expected Mi or Gi" ;;
esac
case "${CURRENT_MIB}" in
    ''|*[!0-9]*) fail "invalid numeric memory quantity ${CURRENT_MEM}" ;;
esac
[ "${CURRENT_MIB}" -gt 0 ] || fail "memory quantity must be greater than zero: ${CURRENT_MEM}"
NEW_LIMIT="$((CURRENT_MIB + MEMORY_INCREASE_MIB))Mi"

RELATIVE_DEPLOYMENT_FILE="${DEPLOYMENT_FILE#"${REPOSITORY_DIR}"/}"
echo "  Target file: ${RELATIVE_DEPLOYMENT_FILE}"
echo "  Forward change: memory limit ${CURRENT_MEM} -> ${NEW_LIMIT} (+${MEMORY_INCREASE_MIB}Mi; request is preserved)"

UPDATED_FILE="${DEPLOYMENT_FILE}.updated"
awk -v target_name="${TARGET_RESOURCE_NAME}" -v target_ns="${TARGET_RESOURCE_NAMESPACE}" \
    -v new_limit="${NEW_LIMIT}" '
    function reset() { kind=""; name=""; ns=""; in_metadata=0; in_limits=0; changed=0 }
    BEGIN { reset() }
    /^---[[:space:]]*$/ { print; reset(); next }
    /^kind:[[:space:]]*/ { kind=$0; sub(/^kind:[[:space:]]*/, "", kind) }
    /^metadata:[[:space:]]*$/ { in_metadata=1; print; next }
    /^spec:[[:space:]]*$/ { in_metadata=0 }
    in_metadata && /^  name:[[:space:]]*/ {
        name=$0; sub(/^  name:[[:space:]]*/, "", name); gsub(/"/, "", name)
    }
    in_metadata && /^  namespace:[[:space:]]*/ {
        ns=$0; sub(/^  namespace:[[:space:]]*/, "", ns); gsub(/"/, "", ns)
    }
    kind == "Deployment" && name == target_name && ns == target_ns && !changed &&
        /^[[:space:]]+limits:[[:space:]]*$/ { print; in_limits=1; next }
    in_limits && /^[[:space:]]+memory:[[:space:]]*/ {
        match($0, /^[[:space:]]*/); indent=substr($0, RSTART, RLENGTH)
        print indent "memory: \"" new_limit "\""
        changed=1; in_limits=0; next
    }
    { print }
    END { if (!changed) exit 1 }
' "${DEPLOYMENT_FILE}" > "${UPDATED_FILE}" \
    || fail "could not update the memory limit in ${DEPLOYMENT_FILE}"
mv "${UPDATED_FILE}" "${DEPLOYMENT_FILE}"

git -C "${REPOSITORY_DIR}" diff -- "${RELATIVE_DEPLOYMENT_FILE}"
git -C "${REPOSITORY_DIR}" config user.email "kubernaut@kubernaut.ai"
git -C "${REPOSITORY_DIR}" config user.name "Kubernaut Remediation"
git -C "${REPOSITORY_DIR}" add -- "${RELATIVE_DEPLOYMENT_FILE}"
git -C "${REPOSITORY_DIR}" commit -m "fix(operator): increase memory limit after informer OOM" >/dev/null

echo "=== Phase 2: Push branch and open pull request ==="
git -C "${REPOSITORY_DIR}" -c "credential.helper=${GIT_CREDENTIAL_HELPER}" \
    push origin "${PR_BRANCH}" >/dev/null \
    || fail "unable to push remediation branch ${PR_BRANCH}"

PR_PAYLOAD=$(jq -n \
    --arg title "fix(operator): increase memory limit for ${TARGET_RESOURCE_NAME}" \
    --arg head "${PR_BRANCH}" \
    --arg base "${GIT_BRANCH}" \
    --arg body "Kubernaut proposed a forward GitOps change after an informer-cache OOM.\n\nTarget: ${TARGET_RESOURCE_NAMESPACE}/Deployment/${TARGET_RESOURCE_NAME}\nMemory limit: ${CURRENT_MEM} -> ${NEW_LIMIT}\n\nThis PR requires human review and merge. Kubernaut will not merge it or patch the live Deployment." \
    '{title:$title, head:$head, base:$base, body:$body}')

PR_RESPONSE_FILE="${WORK_DIR}/pull-request.json"
PR_HTTP_CODE=$(curl -sS -u "${GIT_USERNAME}:${GIT_PASSWORD}" \
    -o "${PR_RESPONSE_FILE}" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -X POST "${GITEA_API_BASE}/repos/${GIT_OWNER}/${GIT_REPOSITORY}/pulls" \
    -d "${PR_PAYLOAD}" || true)
[ "${PR_HTTP_CODE}" = "201" ] \
    || fail "Gitea pull-request creation failed (HTTP ${PR_HTTP_CODE}): $(cat "${PR_RESPONSE_FILE}")"

PR_NUMBER=$(jq -r '.number // empty' "${PR_RESPONSE_FILE}")
PR_URL=$(jq -r '.html_url // .url // empty' "${PR_RESPONSE_FILE}")
[ -n "${PR_NUMBER}" ] || fail "Gitea returned no pull-request number"

echo "FORWARD_CHANGE_PR_NUMBER=${PR_NUMBER}"
echo "FORWARD_CHANGE_PR_URL=${PR_URL}"
echo "PR_STATE=pending-human-review"
echo "The workflow is intentionally waiting. A human must review and merge ${PR_URL}."
echo "The workflow will fail if the PR is closed unmerged or the bounded wait expires."

echo "=== Phase 3: Wait for the human merge (no auto-merge) ==="
START_TIME=$(date +%s)
DEADLINE=$((START_TIME + PR_WAIT_TIMEOUT_SECONDS))
while :; do
    STATUS_FILE="${WORK_DIR}/pull-request-status.json"
    STATUS_HTTP_CODE=$(curl -sS -u "${GIT_USERNAME}:${GIT_PASSWORD}" \
        -o "${STATUS_FILE}" -w '%{http_code}' \
        "${GITEA_API_BASE}/repos/${GIT_OWNER}/${GIT_REPOSITORY}/pulls/${PR_NUMBER}" || true)
    [ "${STATUS_HTTP_CODE}" = "200" ] \
        || fail "Gitea pull-request status failed (HTTP ${STATUS_HTTP_CODE})"

    PR_STATE=$(jq -r '.state // empty' "${STATUS_FILE}")
    PR_MERGED=$(jq -r '.merged // false' "${STATUS_FILE}")
    if [ "${PR_MERGED}" = "true" ]; then
        MERGE_SHA=$(jq -r '.merge_commit_sha // empty' "${STATUS_FILE}")
        MERGED_BY=$(jq -r '.merged_by.login // .merged_by.full_name // "unknown"' "${STATUS_FILE}")
        [ -n "${MERGE_SHA}" ] || fail "Gitea marked pull request ${PR_NUMBER} merged but returned no merge commit SHA"
        echo "PR_STATE=merged"
        echo "PR_MERGED_COMMIT_SHA=${MERGE_SHA}"
        echo "PR_MERGED_BY=${MERGED_BY}"
        echo "=== SUCCESS: human-merged forward GitOps change; Argo CD may now reconcile ${MERGE_SHA} ==="
        exit 0
    fi

    if [ "${PR_STATE}" = "closed" ]; then
        echo "PR_STATE=closed-unmerged" >&2
        fail "pull request ${PR_NUMBER} was closed without a merge; no remediation was applied"
    fi

    NOW=$(date +%s)
    if [ "${NOW}" -ge "${DEADLINE}" ]; then
        echo "PR_STATE=wait-timeout" >&2
        fail "pull request ${PR_NUMBER} was not merged within ${PR_WAIT_TIMEOUT_SECONDS}s"
    fi

    REMAINING=$((DEADLINE - NOW))
    echo "PR_STATE=pending-human-review remaining=${REMAINING}s"
    sleep "${PR_POLL_INTERVAL_SECONDS}"
done
