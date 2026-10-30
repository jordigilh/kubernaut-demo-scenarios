#!/usr/bin/env bash
# Offline regression tests for protocol-aware Prometheus client discovery.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/prometheus-helper.sh"
TMP_DIR="$(mktemp -d)"
MOCK_BIN="${TMP_DIR}/bin"
trap 'rm -rf "${TMP_DIR}"' EXIT
mkdir -p "${MOCK_BIN}"

cat > "${MOCK_BIN}/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "exec" ]; then
    echo "unexpected kubectl command: $*" >&2
    exit 1
fi

case "$*" in
    *"sh -c"*"printf present"*)
        candidate="${!#}"
        if [ "${PROM_TEST_PROTOCOL}" = "https" ] && \
            [ "${candidate}" = "/etc/prometheus/web_config/secret/monitoring-tls-key/ca.crt" ]; then
            printf 'present'
        else
            printf 'absent'
        fi
        ;;
    *"sh -c"*"tls_server_config"*)
        printf 'plain'
        ;;
    *"sh -c"*"tls_config:"*)
        ;;
    *"curl"*"https://localhost:9090"*|*"curl"*"http://localhost:9090"*)
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
    local output
    output=$(
        PATH="${MOCK_BIN}:${PATH}" \
        PROM_TEST_PROTOCOL="${protocol}" \
        bash -c '
            source "$1"
            prometheus_prepare_connection monitoring prometheus-0
            printf "scheme=%s\n" "$PROMETHEUS_SCHEME"
            prometheus_api_get monitoring prometheus-0 "/api/v1/query?query=up"
        ' _ "${HELPER}"
    )

    grep -Fq "scheme=${protocol}" <<<"${output}" || {
        echo "FAIL: expected ${protocol} scheme" >&2
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
run_case https
echo "PASS: Prometheus helper supports HTTP and HTTPS endpoints"
