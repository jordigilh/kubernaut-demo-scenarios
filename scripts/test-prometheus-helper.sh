#!/usr/bin/env bash
# Offline regression tests for protocol-aware Prometheus client discovery.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/prometheus-helper.sh"
TMP_DIR="$(mktemp -d)"
MOCK_BIN="${TMP_DIR}/bin"
trap 'rm -rf "${TMP_DIR}"' EXIT
mkdir -p "${MOCK_BIN}"

grep -Fq '_prometheus_run_with_timeout 15 kubectl get --raw' "${HELPER}"

cat > "${MOCK_BIN}/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "get" ] && [ "${2:-}" = "--raw" ]; then
    if [ "${PROM_TEST_CLIENTS:-available}" = "none" ]; then
        printf '%s\n' '{"status":"success","data":{"result":[]}}'
        exit 0
    fi
    echo "unexpected API proxy fallback" >&2
    exit 1
fi

if [ "${1:-}" != "exec" ]; then
    echo "unexpected kubectl command: $*" >&2
    exit 1
fi

case "$*" in
    *"sh -c"*"printf present"*)
        candidate="${!#}"
        if { [ "${PROM_TEST_PROTOCOL}" = "https" ] || \
            [ "${PROM_TEST_PROTOCOL}" = "http-with-ca" ]; } && \
            [ "${candidate}" = "/etc/prometheus/web_config/secret/monitoring-tls-key/ca.crt" ]; then
            printf 'present'
        else
            printf 'absent'
        fi
        ;;
    *"sh -c"*"tls_server_config"*)
        if [ "${PROM_TEST_PROTOCOL}" = "https" ] || \
            [ "${PROM_TEST_PROTOCOL}" = "https-no-ca" ]; then
            printf 'tls'
        else
            printf 'plain'
        fi
        ;;
    *"sh -c"*"tls_config:"*)
        ;;
    *"curl"*"https://localhost:9090"*|*"curl"*"http://localhost:9090"*)
        if [ "${PROM_TEST_CLIENTS:-available}" = "none" ]; then
            exit 127
        fi
        printf '%s\n' '{"status":"success","data":{"result":[]}}'
        ;;
    *"wget --help"*)
        if [ "${PROM_TEST_CLIENTS:-available}" = "none" ]; then
            exit 127
        fi
        printf '%s\n' 'BusyBox wget'
        ;;
    *"wget"*"https://localhost:9090"*|*"wget"*"http://localhost:9090"*)
        if [ "${PROM_TEST_CLIENTS:-available}" = "none" ]; then
            exit 127
        fi
        printf '%s\n' '{"status":"success","data":{"result":[]}}'
        ;;
    *)
        echo "unexpected mocked kubectl exec: $*" >&2
        exit 1
        ;;
esac
MOCK_KUBECTL
chmod +x "${MOCK_BIN}/kubectl"

run_case() {
    local protocol="$1"
    local clients="${2:-available}"
    local expected_scheme="${protocol}"
    case "${protocol}" in
        http-with-ca) expected_scheme="http" ;;
        https-no-ca)  expected_scheme="https" ;;
    esac
    local output
    output=$(
        PATH="${MOCK_BIN}:${PATH}" \
        PROM_TEST_PROTOCOL="${protocol}" \
        PROM_TEST_CLIENTS="${clients}" \
        bash -c '
            source "$1"
            prometheus_prepare_connection monitoring prometheus-0
            printf "scheme=%s\n" "$PROMETHEUS_SCHEME"
            prometheus_api_get monitoring prometheus-0 "/api/v1/query?query=up"
        ' _ "${HELPER}"
    )

    grep -Fq "scheme=${expected_scheme}" <<<"${output}" || {
        echo "FAIL: expected ${expected_scheme} scheme for ${protocol}" >&2
        echo "${output}" >&2
        exit 1
    }
    grep -Fq '"status":"success"' <<<"${output}" || {
        echo "FAIL: ${protocol} query did not return Prometheus JSON" >&2
        echo "${output}" >&2
        exit 1
    }
}

run_case http
run_case http-with-ca
run_case https
run_case https-no-ca
run_case https none
echo "PASS: Prometheus helper supports HTTP and HTTPS endpoints"
