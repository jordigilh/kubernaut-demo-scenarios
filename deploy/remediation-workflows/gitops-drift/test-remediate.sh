#!/usr/bin/env bash
# Offline contract checks for the GitOps rollback fallback workflow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMEDIATE="${SCRIPT_DIR}/remediate.sh"
WORKFLOW="${SCRIPT_DIR}/gitops-drift.yaml"

grep -Fq 'status.sync.revision' "${REMEDIATE}"
grep -Fq 'PARENT_WAS_SYNCED' "${REMEDIATE}"
grep -Fq 'refusing to revert an unrelated commit' "${REMEDIATE}"
grep -Fq 'git revert --no-edit --mainline 1' "${REMEDIATE}"
grep -Fq 'git revert --no-edit "${SYNC_REVISION}"' "${REMEDIATE}"
grep -Fq 'infrastructure or an external dependency' "${WORKFLOW}"
grep -Fq 'Do not exclude solely because the exact application cause or source diff is unknown' "${WORKFLOW}"
grep -Fq 'previously synchronized as desired state' "${WORKFLOW}"

if grep -Fq 'a specific bad source commit is identified' "${WORKFLOW}"; then
    echo "FAIL: Agent-facing metadata still requires prior Git commit identification" >&2
    exit 1
fi
if grep -Fq 'runtime drift or resource growth without a bad commit' "${WORKFLOW}"; then
    echo "FAIL: delayed workload regressions must remain eligible for GitOps fallback" >&2
    exit 1
fi

bash -n "${REMEDIATE}"
echo "PASS: GitOps fallback pins Argo revision, validates a synced parent, and fails closed"
