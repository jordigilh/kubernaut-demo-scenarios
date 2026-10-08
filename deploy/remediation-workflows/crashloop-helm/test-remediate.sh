#!/usr/bin/env bash
# Offline regression tests for the HelmRollback target contract.
#
# The execution image receives the RCA target, but helm rollback operates on
# the whole release. These tests exercise representative resource kinds
# without requiring a Kubernetes cluster or a Helm repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMEDIATE="${SCRIPT_DIR}/remediate.sh"
TMP_DIR="$(mktemp -d)"
MOCK_BIN="${TMP_DIR}/bin"
mkdir -p "${MOCK_BIN}"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat > "${MOCK_BIN}/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "get" ]; then
    exit 0
fi

shift
resource="${1:-}"
shift || true

case "${resource}" in
    deployment/worker-rs)
        # Simulate kubernaut#693: the target kind is Deployment but the name
        # is the generated ReplicaSet name.
        if [ "${TEST_TARGET_MODE:-}" = "legacy" ]; then
            exit 1
        fi
        if [[ "$*" == *jsonpath* ]]; then
            printf '%s\n' 'demo-storefront'
        fi
        ;;
    deployment/*|configmap/*|secret/*|service/*|statefulset/*|replicaset/*)
        if [[ "$*" == *jsonpath* ]]; then
            printf '%s\n' 'demo-storefront'
        fi
        ;;
    replicaset)
        name="${1:-}"
        if [ "${TEST_TARGET_MODE:-}" = "legacy" ] && [ "${name}" = "worker-rs" ]; then
            printf '%s\n' 'worker'
        fi
        ;;
    pods)
        # The workflow only reports this count; an empty result is healthy
        # enough for the mocked validation phase.
        ;;
    deployments)
        printf 'worker\t2\t2\n'
        ;;
esac
MOCK_KUBECTL

cat > "${MOCK_BIN}/helm" <<'MOCK_HELM'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list)
        printf '%s\n' 'demo-storefront'
        ;;
    history)
        count=0
        if [ -s "${TEST_HELM_STATE}" ]; then
            count=$(cat "${TEST_HELM_STATE}")
        fi
        if [ "${count}" -eq 0 ]; then
            printf '%s\n' '[{"revision":2}]'
        else
            printf '%s\n' '[{"revision":3}]'
        fi
        printf '%s\n' "$((count + 1))" > "${TEST_HELM_STATE}"
        ;;
    status)
        printf '%s\n' '{"info":{"status":"deployed"}}'
        ;;
    rollback)
        printf '%s\n' "$*" >> "${TEST_HELM_LOG}"
        ;;
    *)
        echo "unexpected helm command: $*" >&2
        exit 1
        ;;
esac
MOCK_HELM

chmod +x "${MOCK_BIN}/kubectl" "${MOCK_BIN}/helm"

assert_output() {
    local output="$1"
    local expected="$2"
    if ! grep -Fq "${expected}" <<<"${output}"; then
        echo "FAIL: expected output to contain: ${expected}" >&2
        echo "--- output ---" >&2
        echo "${output}" >&2
        exit 1
    fi
}

run_case() {
    local mode="$1"
    local kind="$2"
    local name="$3"
    local expected="$4"
    local state="${TMP_DIR}/${mode}.state"
    local log="${TMP_DIR}/${mode}.log"
    local output

    : > "${state}"
    : > "${log}"
    output=$(
        PATH="${MOCK_BIN}:${PATH}" \
        TEST_TARGET_MODE="${mode}" \
        TEST_HELM_STATE="${state}" \
        TEST_HELM_LOG="${log}" \
        TARGET_RESOURCE_NAMESPACE="demo-storefront" \
        TARGET_RESOURCE_NAME="${name}" \
        TARGET_RESOURCE_KIND="${kind}" \
        sh "${REMEDIATE}" 2>&1
    )

    assert_output "${output}" "${expected}"
    assert_output "${output}" "SUCCESS: Helm release rolled back"
    if ! grep -Fq 'demo-storefront 1' "${log}"; then
        echo "FAIL: ${kind}/${name} did not roll back demo-storefront to revision 1" >&2
        cat "${log}" >&2
        exit 1
    fi
}

grep -Fq 'component: ["*"]' "${SCRIPT_DIR}/crashloop-helm.yaml" \
    || { echo 'FAIL: workflow component selector is not wildcarded' >&2; exit 1; }

run_case configmap ConfigMap worker-config 'Target: ConfigMap/worker-config'
run_case secret Secret app-credentials 'Target: Secret/app-credentials'
run_case deployment Deployment worker 'Target: Deployment/worker'
run_case legacy Deployment worker-rs 'resolved to Deployment '\''worker'\'''

echo "PASS: HelmRollback accepts arbitrary release resources and preserves ReplicaSet compatibility"
