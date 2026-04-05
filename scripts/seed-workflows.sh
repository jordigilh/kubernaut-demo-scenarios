#!/usr/bin/env bash
# Apply RemediationWorkflow CRDs from deploy/remediation-workflows/.
# The DataStorage controller reconciles them into the workflow catalog.
#
# Workflows are filtered before applying:
#   - engine: ansible  → skipped (requires AWX infrastructure)
#   - dependencies.secrets → skipped when the secret does not exist in the
#     target namespace (e.g. gitea-repo-creds for GitOps scenarios)
#
# Usage:
#   ./scripts/seed-workflows.sh
#   ./scripts/seed-workflows.sh --scenario crashloop
#   ./scripts/seed-workflows.sh --continue-on-error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="${SCRIPT_DIR}/../deploy/remediation-workflows"
NAMESPACE="${PLATFORM_NS:-kubernaut-system}"
SINGLE_SCENARIO=""
CONTINUE_ON_ERROR=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario) SINGLE_SCENARIO="$2"; shift 2 ;;
        --continue-on-error) CONTINUE_ON_ERROR=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

applied=0
skipped=0
fail_count=0
failed_names=()

# Pre-create gitea-repo-creds if Gitea is installed but the secret is missing.
# Without this, workflows declaring a gitea-repo-creds dependency are skipped (#209).
if kubectl get namespace gitea &>/dev/null; then
    GITEA_USER="${GITEA_ADMIN_USER:-kubernaut}"
    GITEA_PASS="${GITEA_ADMIN_PASS:-kubernaut123}"
    for _ns in "${NAMESPACE}" "${WE_NAMESPACE:-kubernaut-workflows}"; do
        if kubectl get namespace "$_ns" &>/dev/null && \
           ! kubectl get secret gitea-repo-creds -n "$_ns" &>/dev/null; then
            kubectl create secret generic gitea-repo-creds \
              -n "$_ns" \
              --from-literal=username="${GITEA_USER}" \
              --from-literal=password="${GITEA_PASS}" \
              --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
            echo "  Pre-created gitea-repo-creds in ${_ns}"
        fi
    done
fi

_apply_workflow_yaml() {
    local yaml_file="$1" ns="$2"
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '${tmpdir}'" RETURN

    kubectl create namespace "${WE_NAMESPACE:-kubernaut-workflows}" \
        --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - 2>/dev/null || true

    awk -v dir="$tmpdir" \
        'BEGIN{n=0} /^---$/{n++; next} {print >> dir"/doc-"n".yaml"}' "$yaml_file"

    for doc in "$tmpdir"/doc-*.yaml; do
        [ -f "$doc" ] || continue
        if grep -q 'kind: RemediationWorkflow' "$doc"; then
            kubectl apply -n "$ns" -f "$doc" 2>&1
        else
            kubectl apply -f "$doc" 2>&1
        fi
    done
}

echo "==> Applying RemediationWorkflow CRDs from ${WORKFLOWS_DIR}"
while IFS= read -r -d '' yaml_file; do
    basename="${yaml_file##*/}"

    if [ -n "$SINGLE_SCENARIO" ]; then
        dir_name="$(basename "$(dirname "$yaml_file")")"
        if [ "$dir_name" != "$SINGLE_SCENARIO" ]; then
            continue
        fi
    fi

    # Skip Ansible-engine workflows unless AWX is available
    if grep -q 'engine: ansible' "$yaml_file"; then
        if ! kubectl get deployment -A -l 'app.kubernetes.io/managed-by=awx-operator' --no-headers 2>/dev/null | grep -q . && \
           ! kubectl get automationcontroller -A --no-headers 2>/dev/null | grep -q .; then
            echo "  SKIP ${basename} (engine: ansible — no AWX/AAP found)"
            skipped=$((skipped + 1))
            continue
        fi
    fi

    # Check secret dependencies declared in the workflow.
    # WE jobs run in kubernaut-workflows, so check both the platform namespace
    # and the workflow execution namespace (DD-WE-006).
    WE_NAMESPACE="${WE_NAMESPACE:-kubernaut-workflows}"
    unmet=""
    while IFS= read -r secret_name; do
        if ! kubectl get secret "$secret_name" -n "${NAMESPACE}" &>/dev/null && \
           ! kubectl get secret "$secret_name" -n "${WE_NAMESPACE}" &>/dev/null; then
            unmet="${secret_name}"
            break
        fi
    done < <(grep -A1 'secrets:' "$yaml_file" 2>/dev/null \
              | grep -- '- name:' | awk '{print $NF}')

    if [ -n "$unmet" ]; then
        echo "  SKIP ${basename} (secret \"${unmet}\" not found in ${NAMESPACE} or ${WE_NAMESPACE})"
        skipped=$((skipped + 1))
        continue
    fi

    if _apply_workflow_yaml "$yaml_file" "$NAMESPACE" 2>&1 | sed 's/^/  /'; then
        applied=$((applied + 1))
    else
        fail_count=$((fail_count + 1))
        failed_names+=("${basename}")
        if [ "$CONTINUE_ON_ERROR" = false ]; then
            echo ""
            echo "ERROR: Failed to apply ${basename}. Use --continue-on-error to skip failures."
            exit 1
        fi
    fi
done < <(find "${WORKFLOWS_DIR}" -name '*.yaml' -print0)

echo "==> Done. Applied ${applied} workflow(s), skipped ${skipped}, failed ${fail_count}."

if [ "$fail_count" -gt 0 ]; then
    echo "  Failed workflows:"
    for name in "${failed_names[@]}"; do
        echo "    - ${name}"
    done
fi

echo "  Verify: kubectl get remediationworkflows -n ${NAMESPACE}"

[ "$fail_count" -eq 0 ]
