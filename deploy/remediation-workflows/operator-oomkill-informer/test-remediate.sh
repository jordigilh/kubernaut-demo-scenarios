#!/usr/bin/env bash
# Offline contract checks for the #446 GitOps forward-change workflow.
# The real PR lifecycle is exercised against Gitea in the two-cluster
# rehearsal; these checks protect the non-negotiable safety boundary in CI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMEDIATE="${SCRIPT_DIR}/remediate.sh"
WORKFLOW="${SCRIPT_DIR}/operator-oomkill-informer.yaml"

grep -Fq 'clusterId: hub' "${WORKFLOW}"
grep -Fq 'name: gitea-repo-creds' "${WORKFLOW}"
grep -Fq 'dependencies:' "${WORKFLOW}"
grep -Fq 'gitOpsManaged: true' "${WORKFLOW}"
grep -Fq 'gitOpsTool: argocd' "${WORKFLOW}"
grep -Fq 'required_approvals' "${REMEDIATE}" 2>/dev/null && {
    echo "FAIL: branch-protection configuration belongs in scenario setup, not the Job" >&2
    exit 1
} || true

if grep -Eq 'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push[[:space:]].*origin[[:space:]]+main|/pulls/.*/merge|/merge"' "${REMEDIATE}"; then
    echo "FAIL: workflow contains a direct protected-main push or merge API call" >&2
    exit 1
fi
if grep -Eq 'kubectl[[:space:]].*(patch|apply|edit)[[:space:]]' "${REMEDIATE}"; then
    echo "FAIL: workflow mutates a live Kubernetes resource" >&2
    exit 1
fi
grep -Fq 'closed-unmerged' "${REMEDIATE}"
grep -Fq 'wait-timeout' "${REMEDIATE}"
grep -Fq 'PR_STATE=merged' "${REMEDIATE}"
grep -Fq 'MEMORY_INCREASE_MIB=128' "${REMEDIATE}"
if grep -Eq 'MAX_MEMORY_REMEDIATION_RUNS|PRIOR_MEMORY_REMEDIATIONS|HUMAN_HANDOFF_REQUIRED' "${REMEDIATE}"; then
    echo "FAIL: recurrence limits and human handoff decisions belong to platform routing/history, not the workflow Job" >&2
    exit 1
fi
grep -Fq 'fixed 128Mi increment' "${WORKFLOW}"
if grep -Fq 'MEMORY_INCREASE_FACTOR' "${REMEDIATE}" || grep -Fq 'MEMORY_INCREASE_FACTOR' "${WORKFLOW}"; then
    echo "FAIL: fixed +128Mi GitOps workflow still exposes MEMORY_INCREASE_FACTOR" >&2
    exit 1
fi

bash -n "${REMEDIATE}"
echo "PASS: GitOps workflow is hub-executed, PR-only, merge-gated, fixed-increment, and RR-agnostic"
