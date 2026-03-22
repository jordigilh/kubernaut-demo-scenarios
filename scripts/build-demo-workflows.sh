#!/usr/bin/env bash
# Build and push demo scenario execution images to quay.io/kubernaut-cicd/test-workflows
#
# Each scenario produces one execution image (<name>:v<spec.version>) containing
# remediate.sh + tools, run by WorkflowExecution as a K8s Job.
# Image tags are immutable: each rebuild bumps spec.version and pushes to a new
# tag, so old digest-pinned references stay resolvable (#139).
#
# After pushing, the manifest list digest is written back into
# deploy/remediation-workflows/<scenario>.yaml so the bundle reference stays in sync.
#
# Authority: BR-WE-014 (Kubernetes Job Execution Backend)
#
# Usage:
#   ./build-demo-workflows.sh                    # Build and push multi-arch (amd64 + arm64)
#   ./build-demo-workflows.sh --arch arm64       # Build and push single arch (arm64 only)
#   ./build-demo-workflows.sh --local            # Build local-only (no push, current arch)
#   ./build-demo-workflows.sh --scenario NAME    # Build a single scenario
#   ./build-demo-workflows.sh --scenario crashloop --seed
#
# Prerequisites:
#   - podman login quay.io (for push)
#   - podman with multi-arch manifest support
#   - skopeo (for registry manifest inspection)
#   - python3 (for digest computation)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="${SCRIPT_DIR}/../deploy/remediation-workflows"
REGISTRY="quay.io/kubernaut-cicd/test-workflows"
VERSION_OVERRIDE=""
LOCAL_ONLY=false
SINGLE_SCENARIO=""
SEED_AFTER=false
ARCHITECTURES=(amd64 arm64)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)
            LOCAL_ONLY=true
            shift
            ;;
        --scenario)
            SINGLE_SCENARIO="$2"
            shift 2
            ;;
        --version)
            VERSION_OVERRIDE="$2"
            shift 2
            ;;
        --arch)
            IFS=',' read -ra ARCHITECTURES <<< "$2"
            shift 2
            ;;
        --seed)
            SEED_AFTER=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--local] [--arch ARCH[,ARCH]] [--scenario NAME] [--version TAG] [--seed]"
            echo ""
            echo "Options:"
            echo "  --local            Build for current arch only (no push)"
            echo "  --arch ARCH        Comma-separated architectures (default: amd64,arm64)"
            echo "  --scenario NAME    Build a single scenario (e.g., crashloop)"
            echo "  --version TAG      Override version tag (default: derived from spec.version)"
            echo "  --seed             Register workflow(s) in DataStorage after push"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "============================================"
echo "Building Demo Scenario Workflow Images"
echo "============================================"
echo "Registry: ${REGISTRY}"
echo "Tag:      $(if [ -n "$VERSION_OVERRIDE" ]; then echo "${VERSION_OVERRIDE} (override)"; else echo 'v<spec.version> (immutable, per-workflow)'; fi)"
echo "Mode:     $(if $LOCAL_ONLY; then echo 'LOCAL ONLY (current arch)'; else echo "PUSH (${ARCHITECTURES[*]})"; fi)"
if [ -n "$SINGLE_SCENARIO" ]; then
    echo "Scenario: ${SINGLE_SCENARIO}"
fi
echo ""

# scenario-dir:image-name mappings (shared across build + seed scripts)
# shellcheck source=workflow-mappings.sh
source "${SCRIPT_DIR}/workflow-mappings.sh"

# build_and_push builds images for each architecture in ARCHITECTURES, creates a
# manifest list, pushes it, and prints the manifest list digest to stdout.
# All podman build/push output goes to stderr so only the digest reaches stdout.
#
# Per-arch images are pushed individually first so that `podman manifest add`
# can resolve them from the registry. This avoids "manifest unknown" errors
# with rootless podman on CI runners where local-storage lookups for
# registry-prefixed tags fail silently.
#
# Args: $1=full_ref $2=dockerfile $3=context_dir
build_and_push() {
    local ref="$1" dockerfile="$2" context="$3"

    for arch in "${ARCHITECTURES[@]}"; do
        podman build --platform "linux/${arch}" -t "${ref}-${arch}" -f "${dockerfile}" "${context}" >&2
        podman push "${ref}-${arch}" "docker://${ref}-${arch}" >&2
    done

    podman manifest rm "${ref}" &>/dev/null || true
    podman manifest create "${ref}" >/dev/null
    for arch in "${ARCHITECTURES[@]}"; do
        local attempt
        for attempt in 1 2 3; do
            if podman manifest add "${ref}" "docker://${ref}-${arch}" >/dev/null 2>&1; then
                break
            fi
            if [ "$attempt" -eq 3 ]; then
                echo "ERROR: podman manifest add failed for ${arch} after 3 attempts" >&2
                return 1
            fi
            local wait=$(( attempt * 5 ))
            echo "  Retry ${attempt}/3: manifest add for ${arch} (waiting ${wait}s for registry propagation)..." >&2
            sleep "$wait"
        done
    done
    podman manifest push "${ref}" "docker://${ref}" >&2

    skopeo inspect --raw "docker://${ref}" 2>/dev/null | \
        python3 -c "import sys,hashlib; data=sys.stdin.buffer.read(); print('sha256:'+hashlib.sha256(data).hexdigest())"
}

# build_local builds for the current arch only and prints the image digest.
# Falls back to the image ID (sha256:...) when no registry digest is available.
# Args: $1=full_ref $2=dockerfile $3=context_dir
build_local() {
    local ref="$1" dockerfile="$2" context="$3"
    podman build -t "${ref}" -f "${dockerfile}" "${context}" >&2
    local digest
    digest=$(podman inspect "${ref}" --format '{{.Digest}}' 2>/dev/null || echo "")
    if [ -z "${digest}" ] || [ "${digest}" = "<none>" ]; then
        digest=$(podman inspect "${ref}" --format '{{.Id}}' 2>/dev/null || echo "")
    fi
    echo "${digest}"
}

# update_bundle_digest writes the exec image digest into the workflow CRD YAML
# Replaces the bundle line precisely, discarding any trailing garbage.
# Args: $1=schema_file $2=registry/image_name $3=digest
update_bundle_digest() {
    local schema_file="$1" image_ref="$2" digest="$3"
    local new_bundle="${image_ref}@${digest}"
    python3 -c "
import re, sys
f, new = sys.argv[1], sys.argv[2]
with open(f) as fh: content = fh.read()
# Replace the bundle line and any non-YAML garbage that may follow it
# (from previous broken runs where build output leaked into the file).
# Match from 'bundle: ...' up to the next blank line or YAML key.
content = re.sub(
    r'(    bundle: ).*?(?=\n\n|\n    parameters:|\n    detectedLabels:|\n  parameters:|\Z)',
    r'\g<1>' + new,
    content,
    flags=re.DOTALL
)
with open(f, 'w') as fh: fh.write(content)
" "${schema_file}" "${new_bundle}"
}

# read_spec_version extracts the current spec.version from a workflow YAML.
# Args: $1=schema_file  Output: version string (e.g., "1.0.3") on stdout
read_spec_version() {
    local schema_file="$1"
    python3 -c "
import re, sys
with open(sys.argv[1]) as fh:
    m = re.search(r'  version: [\"'\'']?(\d+\.\d+\.\d+)', fh.read())
    print(m.group(1) if m else '')
" "$schema_file"
}

# bump_patch_version increments the patch segment of spec.version in
# the workflow CRD YAML (e.g., 1.8.0 -> 1.8.1) so the DataStorage detects
# the schema as a new version after a digest-only change.
# Args: $1=schema_file
bump_patch_version() {
    local schema_file="$1"
    python3 -c "
import re, sys
f = sys.argv[1]
with open(f) as fh:
    content = fh.read()
def _bump(m):
    prefix, major, minor, patch = m.group(1), m.group(2), m.group(3), int(m.group(4))
    return f'{prefix}{major}.{minor}.{patch + 1}'
content, n = re.subn(r'(  version: )(\d+)\.(\d+)\.(\d+)', _bump, content, count=1)
if n == 0:
    print('WARNING: no spec.version found to bump', file=sys.stderr)
    sys.exit(0)
with open(f, 'w') as fh:
    fh.write(content)
m = re.search(r'version: (\S+)', content)
print(m.group(1) if m else 'unknown')
" "${schema_file}"
}

build_count=0
skip_count=0
declare -A BUILT_DIGESTS  # image-name -> digest for reconciliation pass

for entry in "${WORKFLOWS[@]}"; do
    SCENARIO="${entry%%:*}"
    IMAGE_NAME="${entry#*:}"
    BUILD_DIR="${WORKFLOWS_DIR}/${SCENARIO}"
    SCHEMA_FILE="${BUILD_DIR}/${SCENARIO}.yaml"

    if [ -n "$SINGLE_SCENARIO" ] && [ "$SCENARIO" != "$SINGLE_SCENARIO" ]; then
        skip_count=$((skip_count + 1))
        continue
    fi

    if [ ! -f "${BUILD_DIR}/Dockerfile.exec" ]; then
        echo "SKIP: ${SCENARIO} -- no Dockerfile.exec at deploy/remediation-workflows/${SCENARIO}/Dockerfile.exec"
        skip_count=$((skip_count + 1))
        continue
    fi

    if [ ! -f "${SCHEMA_FILE}" ]; then
        echo "ERROR: ${SCENARIO} -- missing deploy/remediation-workflows/${SCENARIO}/${SCENARIO}.yaml (required by ADR-043)"
        exit 1
    fi

    # Determine image tag: --version override, or bump spec.version for an
    # immutable tag that won't orphan old digests (#139).
    if [ -n "${VERSION_OVERRIDE}" ]; then
        IMAGE_TAG="${VERSION_OVERRIDE}"
    elif ! $LOCAL_ONLY; then
        new_ver=$(bump_patch_version "${SCHEMA_FILE}")
        IMAGE_TAG="v${new_ver}"
        echo "  [version] Bumped spec.version -> ${new_ver}"
    else
        cur_ver=$(read_spec_version "${SCHEMA_FILE}")
        IMAGE_TAG="v${cur_ver:-0.0.0}"
    fi

    EXEC_REF="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    echo "==> ${IMAGE_NAME}:${IMAGE_TAG} (scenario: ${SCENARIO})"

    # Step 1: Build and push execution image
    echo "  [exec] Building ${EXEC_REF}..."
    if $LOCAL_ONLY; then
        EXEC_DIGEST=$(build_local "${EXEC_REF}" "${BUILD_DIR}/Dockerfile.exec" "${BUILD_DIR}")
        echo "  [exec] Built (local arch only)"
    else
        EXEC_DIGEST=$(build_and_push "${EXEC_REF}" "${BUILD_DIR}/Dockerfile.exec" "${BUILD_DIR}")
        echo "  [exec] Pushed. Digest: ${EXEC_DIGEST}"
    fi

    # Step 2: Update workflow CRD with exec image digest
    if [ -n "${EXEC_DIGEST}" ]; then
        BUILT_DIGESTS["${IMAGE_NAME}"]="${EXEC_DIGEST}"
        update_bundle_digest "${SCHEMA_FILE}" "${REGISTRY}/${IMAGE_NAME}" "${EXEC_DIGEST}"
        echo "  [digest] Updated execution.bundle in ${SCENARIO}.yaml"
    else
        echo "  [digest] WARNING: Could not extract digest, schema not updated"
    fi

    build_count=$((build_count + 1))
    echo ""
done

# ---------------------------------------------------------------------------
# Reconciliation pass: update any *other* workflow YAML that references a
# just-built image with a stale digest.  This covers workflows that reuse an
# image owned by a different scenario (e.g. concurrent-cross-namespace/
# restart-pods-v1 shares graceful-restart-job with memory-leak).
# ---------------------------------------------------------------------------
if [ "${#BUILT_DIGESTS[@]}" -gt 0 ]; then
    reconcile_count=0
    while IFS= read -r -d '' yaml_file; do
        for img_name in "${!BUILT_DIGESTS[@]}"; do
            current_digest="${BUILT_DIGESTS[$img_name]}"
            full_ref="${REGISTRY}/${img_name}"
            if grep -q "bundle:.*${full_ref}" "${yaml_file}" && \
               ! grep -q "bundle: ${full_ref}@${current_digest}" "${yaml_file}"; then
                update_bundle_digest "${yaml_file}" "${full_ref}" "${current_digest}"
                if ! $LOCAL_ONLY; then
                    new_ver=$(bump_patch_version "${yaml_file}")
                    echo "  [reconcile] ${yaml_file##*/}: updated ${img_name} digest, version -> ${new_ver}"
                else
                    echo "  [reconcile] ${yaml_file##*/}: updated ${img_name} digest"
                fi
                reconcile_count=$((reconcile_count + 1))
            fi
        done
    done < <(find "${WORKFLOWS_DIR}" -name '*.yaml' -print0)
    if [ "$reconcile_count" -gt 0 ]; then
        echo ""
        echo "Reconciled ${reconcile_count} shared-image reference(s)."
    fi
fi

echo ""
echo "============================================"
echo "Built: ${build_count} scenario(s)"
if [ "$skip_count" -gt 0 ]; then
    echo "Skipped: ${skip_count}"
fi
if ! $LOCAL_ONLY; then
    echo "Pushed to: ${REGISTRY}"
fi
echo "============================================"

if [ -n "$SINGLE_SCENARIO" ] && [ "$build_count" -eq 0 ]; then
    echo "ERROR: Scenario '${SINGLE_SCENARIO}' not found in workflow mappings."
    echo "Available scenarios: $(printf '%s\n' "${WORKFLOWS[@]}" | cut -d: -f1 | tr '\n' ' ')"
    exit 1
fi

if $SEED_AFTER && ! $LOCAL_ONLY && [ "$build_count" -gt 0 ]; then
    echo ""
    echo "==> Applying RemediationWorkflow CRDs..."
    SEED_ARGS=()
    if [ -n "$SINGLE_SCENARIO" ]; then
        SEED_ARGS+=(--scenario "${SINGLE_SCENARIO}")
    fi
    bash "${SCRIPT_DIR}/seed-workflows.sh" "${SEED_ARGS[@]}"
fi

if ! $SEED_AFTER; then
    echo ""
    echo "Next steps:"
    echo "  Apply RemediationWorkflow CRDs:"
    echo "    ./scripts/seed-workflows.sh"
fi
