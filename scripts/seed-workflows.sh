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
FLEET_MODE=false

if [ -n "${HUB_KUBECONFIG:-}" ] || [ -n "${SPOKE_KUBECONFIG:-}" ]; then
    if [ -z "${HUB_KUBECONFIG:-}" ] || [ -z "${SPOKE_KUBECONFIG:-}" ]; then
        echo "ERROR: fleet seeding requires both HUB_KUBECONFIG and SPOKE_KUBECONFIG." >&2
        exit 1
    fi
    FLEET_MODE=true
    export KUBECONFIG="${HUB_KUBECONFIG}"
    echo "==> Fleet mode: targeting workflows and dependencies at hub ${HUB_KUBECONFIG}"
    echo "    (git-revert-v2 execution.clusterId: ${FLEET_EXECUTION_CLUSTER_ID:-hub (hardcoded)})"
fi

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
    _ns="${WE_NAMESPACE:-kubernaut-workflows}"
    if kubectl get namespace "$_ns" &>/dev/null && \
       ! kubectl get secret gitea-repo-creds -n "$_ns" &>/dev/null; then
        kubectl create secret generic gitea-repo-creds \
          -n "$_ns" \
          --from-literal=username="${GITEA_USER}" \
          --from-literal=password="${GITEA_PASS}" \
          --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
        echo "  Pre-created gitea-repo-creds in ${_ns}"
    fi
fi

# Fleet-only: apply a workflow file's RBAC documents (ServiceAccount, Role,
# ClusterRole, RoleBinding, ClusterRoleBinding) to the spoke cluster, so
# Jobs the hub schedules there find their runner identity.
# Deliberately skips Secrets (repository credentials must never land on the
# spoke -- setup-demo-cluster.sh validates their absence) and
# RemediationWorkflow CRs (the catalog lives on the hub). Requires
# SPOKE_KUBECONFIG (always set in fleet mode).
_apply_workflow_rbac_to_spoke() {
    local yaml_file="$1"
    if [ -z "${SPOKE_KUBECONFIG:-}" ]; then
        echo "WARNING: FLEET_MODE without SPOKE_KUBECONFIG; skipping spoke RBAC for ${yaml_file}." >&2
        return 0
    fi
    local tmpdir
    tmpdir=$(mktemp -d)
    # Double quotes: expand now so the trap holds the literal path (a
    # single-quoted '${tmpdir}' evaluates at RETURN time, when the local is
    # out of scope under `set -u`).
    trap "rm -rf '${tmpdir}'" RETURN

    python3 -c "
import sys, os, re
d = sys.argv[1]
docs, cur = [], []
for line in open(sys.argv[2]):
    if line.strip() == '---':
        if cur: docs.append(''.join(cur)); cur = []
    else:
        cur.append(line)
if cur: docs.append(''.join(cur))
n = 0
for i, doc in enumerate(docs):
    if re.search(r'^kind: (ServiceAccount|Role|ClusterRole|RoleBinding|ClusterRoleBinding)\s*$', doc, re.M):
        open(os.path.join(d, f'rbac-{n}.yaml'), 'w').write(doc)
        n += 1
print(n)
" "${tmpdir}" "${yaml_file}"

    local rbac_applied=0
    for doc in "${tmpdir}"/rbac-*.yaml; do
        [ -f "$doc" ] || continue
        kubectl --kubeconfig="${SPOKE_KUBECONFIG}" apply -f "$doc" 2>&1 | sed 's/^/    [spoke] /'
        rbac_applied=$((rbac_applied + 1))
    done
    [ "$rbac_applied" -gt 0 ] || echo "    [spoke] no RBAC documents in ${yaml_file##*/}, nothing mirrored."
}

_apply_workflow_yaml() {
    local yaml_file="$1" ns="$2"
    local tmpdir
    tmpdir=$(mktemp -d)
    # Double quotes: expand now so the trap holds the literal path (a
    # single-quoted '${tmpdir}' evaluates at RETURN time, when the local is
    # out of scope under `set -u`).
    trap "rm -rf '${tmpdir}'" RETURN

    local rendered_yaml="${yaml_file}"
    if [ -n "${FLEET_EXECUTION_CLUSTER_ID:-}" ] && grep -q 'name: git-revert-v2' "$yaml_file"; then
        # Explicit override for third environments whose hub id is not "hub"
        # (the file hardcodes execution.clusterId: hub).
        rendered_yaml="${tmpdir}/rendered-workflow.yaml"
        python3 - "$yaml_file" "$rendered_yaml" "${FLEET_EXECUTION_CLUSTER_ID}" <<'PYEOF'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
override = sys.argv[3]
needle = "  execution:\n"
if needle not in source:
    raise SystemExit("workflow has no execution block")
out = []
in_execution = False
for line in source.splitlines(keepends=True):
    if line == needle:
        in_execution = True
        out.append(line)
        continue
    if in_execution and line.startswith("    clusterId:"):
        out.append(f"    clusterId: {override}\n")
        continue
    if in_execution and re.match(r"  \S", line):
        in_execution = False
    out.append(line)
pathlib.Path(sys.argv[2]).write_text("".join(out))
PYEOF
    fi

    kubectl create namespace "${WE_NAMESPACE:-kubernaut-workflows}" \
        --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - 2>/dev/null || true

    python3 -c "
import sys, os
d, n, f = sys.argv[1], 0, None
for line in open(sys.argv[2]):
    if line.strip() == '---':
        n += 1; f = None; continue
    if f is None: f = open(os.path.join(d, f'doc-{n}.yaml'), 'a')
    f.write(line)
" "$tmpdir" "$rendered_yaml"

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
        # Fleet: the hub owns the catalog, but remotely-executed Jobs run on
        # the spoke under the workflow's runner identity -- mirror that
        # file's RBAC there now, or the Job pods fail with
        # 'serviceaccount "..." not found' (seen live with
        # crashloop-rollback-v1-runner).
        if [ "$FLEET_MODE" = true ]; then
            _apply_workflow_rbac_to_spoke "$yaml_file" 2>&1 | sed 's/^/  /' || true
        fi
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
