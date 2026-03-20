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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="${SCRIPT_DIR}/../deploy/remediation-workflows"
NAMESPACE="${PLATFORM_NS:-kubernaut-system}"
SINGLE_SCENARIO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario) SINGLE_SCENARIO="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

applied=0
skipped=0

echo "==> Applying RemediationWorkflow CRDs from ${WORKFLOWS_DIR}"
while IFS= read -r -d '' yaml_file; do
    basename="${yaml_file##*/}"

    if [ -n "$SINGLE_SCENARIO" ]; then
        dir_name="$(basename "$(dirname "$yaml_file")")"
        if [ "$dir_name" != "$SINGLE_SCENARIO" ]; then
            continue
        fi
    fi

    # Skip Ansible-engine workflows unless AWX or AAP is available
    if grep -q 'engine: ansible' "$yaml_file"; then
        if ! kubectl get deployment -A -l 'app.kubernetes.io/name=awx' --no-headers 2>/dev/null | grep -q . && \
           ! kubectl get automationcontroller -A --no-headers 2>/dev/null | grep -q .; then
            echo "  SKIP ${basename} (engine: ansible — no AWX/AAP found)"
            skipped=$((skipped + 1))
            continue
        fi
    fi

    # Check secret dependencies declared in the workflow
    unmet=""
    while IFS= read -r secret_name; do
        if ! kubectl get secret "$secret_name" -n "${NAMESPACE}" &>/dev/null; then
            unmet="${secret_name}"
            break
        fi
    done < <(grep -A1 'secrets:' "$yaml_file" 2>/dev/null \
              | grep -- '- name:' | awk '{print $NF}')

    if [ -n "$unmet" ]; then
        echo "  SKIP ${basename} (secret \"${unmet}\" not found in ${NAMESPACE})"
        skipped=$((skipped + 1))
        continue
    fi

    kubectl apply -n "$NAMESPACE" -f "$yaml_file" 2>&1 | sed 's/^/  /' || true
    applied=$((applied + 1))
done < <(find "${WORKFLOWS_DIR}" -name '*.yaml' -print0)

echo "==> Done. Applied ${applied} workflow(s), skipped ${skipped}."
echo "  Verify: kubectl get remediationworkflows -n ${NAMESPACE}"
