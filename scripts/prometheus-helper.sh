#!/usr/bin/env bash
# Shared Prometheus client configuration for in-pod queries.
# Operator-managed Prometheus may serve HTTPS; older demo stacks may use HTTP.

PROMETHEUS_CONNECTION_TARGET="${PROMETHEUS_CONNECTION_TARGET:-}"
PROMETHEUS_SCHEME="${PROMETHEUS_SCHEME:-}"
PROMETHEUS_CA_FILE="${PROMETHEUS_CA_FILE:-}"
PROMETHEUS_HTTP_CONFIG_FILE="${PROMETHEUS_HTTP_CONFIG_FILE:-}"

# Run a Prometheus client operation with a portable wall-clock deadline.
_prometheus_run_with_timeout() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${seconds}" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "${seconds}" "$@"
    fi
}

# Detect the target's Prometheus scheme and prepare its client CA/config.
# The result is cached per Prometheus pod so repeated preflight polls do not
# repeatedly inspect the mounted certificate paths.
prometheus_prepare_connection() {
    local prom_namespace="${1:?prometheus_prepare_connection requires a namespace}"
    local prom_pod="${2:?prometheus_prepare_connection requires a pod}"
    local target="${prom_namespace}/${prom_pod}"

    if [ "${PROMETHEUS_CONNECTION_TARGET}" = "${target}" ] && \
        [ -n "${PROMETHEUS_SCHEME}" ]; then
        return 0
    fi

    local tls_result
    # Determine the serving protocol from Prometheus' web configuration first.
    # A CA mount can also be used for outbound scraping and must not select
    # HTTPS by itself.
    # shellcheck disable=SC2016 # The expression is evaluated inside the pod.
    if ! tls_result=$(_prometheus_run_with_timeout 10 kubectl exec \
        -n "${prom_namespace}" "${prom_pod}" -c prometheus -- \
        sh -c 'if [ -f "$1" ] && grep -q "^[[:space:]]*tls_server_config:" "$1"; then printf tls; else printf plain; fi' -- \
        /etc/prometheus/web_config/web-config.yaml 2>/dev/null); then
        echo "WARNING: could not inspect Prometheus web config in ${target}; retrying discovery." >&2
        return 1
    fi

    local scheme="http"
    [ "${tls_result}" = "tls" ] && scheme="https"

    local ca_file=""
    if [ "${scheme}" = "https" ]; then
        local candidate
        # These paths cover the kube-prometheus-stack/operator secret mounts
        # and the service CA mounts used by OpenShift monitoring.
        for candidate in \
            /etc/prometheus/web_config/secret/monitoring-tls-key/ca.crt \
            /etc/prometheus/web_config/secret/monitoring-tls-cert/ca.crt \
            /etc/monitoring-tls/ca.crt \
            /etc/tls-ca/ca.crt \
            /etc/prometheus/certs/ca.crt \
            /etc/prometheus/configmaps/serving-certs-ca-bundle/service-ca.crt \
            /etc/prometheus/configmaps/serving-certs-ca-bundle/ca-bundle.crt; do
            local probe_result
            # shellcheck disable=SC2016 # The expression is evaluated inside the pod.
            if ! probe_result=$(_prometheus_run_with_timeout 10 kubectl exec \
                -n "${prom_namespace}" "${prom_pod}" -c prometheus -- \
                sh -c 'if [ -f "$1" ]; then printf present; else printf absent; fi' -- \
                "${candidate}" 2>/dev/null); then
                echo "WARNING: could not inspect Prometheus CA mount ${candidate} in ${target}; retrying discovery." >&2
                return 1
            fi
            if [ "${probe_result}" = "present" ]; then
                ca_file="${candidate}"
                break
            fi
        done
    fi

    if [ "${scheme}" = "https" ]; then
        # /tmp may be read-only in operator-managed Prometheus containers;
        # /dev/shm is writable and suitable for this short-lived config.
        local config_path="${PROMETHEUS_HTTP_CONFIG_PATH:-/dev/shm/kubernaut-prometheus-http-config.yml}"
        local config_line="  insecure_skip_verify: true"
        [ -n "${ca_file}" ] && config_line="  ca_file: ${ca_file}"
        if ! _prometheus_run_with_timeout 10 kubectl exec \
            -n "${prom_namespace}" "${prom_pod}" -c prometheus -- sh -c \
            "printf '%s\\n' 'tls_config:' '${config_line}' > '${config_path}'"; then
            echo "ERROR: could not create the Prometheus TLS client config in ${target}." >&2
            return 1
        fi
        PROMETHEUS_CA_FILE="${ca_file}"
        PROMETHEUS_HTTP_CONFIG_FILE="${config_path}"
    else
        PROMETHEUS_CA_FILE=""
        PROMETHEUS_HTTP_CONFIG_FILE=""
    fi

    PROMETHEUS_CONNECTION_TARGET="${target}"
    PROMETHEUS_SCHEME="${scheme}"
}

# Read a Prometheus HTTP API path through the detected local endpoint.
# Prometheus images do not consistently include curl or wget, so callers can
# fall back to promtool for PromQL queries when neither client is available.
prometheus_api_get() {
    local prom_namespace="${1:?prometheus_api_get requires a namespace}"
    local prom_pod="${2:?prometheus_api_get requires a pod}"
    local api_path="${3:?prometheus_api_get requires an API path}"
    prometheus_prepare_connection "${prom_namespace}" "${prom_pod}" || return 1

    local url="${PROMETHEUS_SCHEME}://localhost:9090${api_path}"
    local curl_args=(-sf --connect-timeout 5 "${url}")
    if [ "${PROMETHEUS_SCHEME}" = "https" ]; then
        if [ -n "${PROMETHEUS_CA_FILE}" ]; then
            curl_args+=(--cacert "${PROMETHEUS_CA_FILE}")
        else
            curl_args+=(-k)
        fi
    fi

    local response
    if response=$(_prometheus_run_with_timeout 15 kubectl exec \
        -n "${prom_namespace}" "${prom_pod}" -c prometheus -- \
        curl "${curl_args[@]}" 2>/dev/null); then
        printf '%s\n' "${response}"
        return 0
    fi

    local wget_args=(-qO- "${url}")
    if [ "${PROMETHEUS_SCHEME}" = "https" ]; then
        if [ -n "${PROMETHEUS_CA_FILE}" ] && \
            kubectl exec -n "${prom_namespace}" "${prom_pod}" -c prometheus -- \
                wget --help 2>&1 | grep -q -- '--ca-certificate'; then
            wget_args+=(--ca-certificate="${PROMETHEUS_CA_FILE}")
        else
            wget_args+=(--no-check-certificate)
        fi
    fi
    if response=$(_prometheus_run_with_timeout 15 kubectl exec \
        -n "${prom_namespace}" "${prom_pod}" -c prometheus -- \
        wget "${wget_args[@]}" 2>/dev/null); then
        printf '%s\n' "${response}"
        return 0
    fi

    # Some supported Prometheus images contain neither curl nor wget. The API
    # server proxy preserves the selected backend protocol and avoids requiring
    # a client binary or a host-side certificate copy. Bound the proxy request
    # as well so an unavailable API server cannot hang scenario preflight.
    local proxy_path="/api/v1/namespaces/${prom_namespace}/pods/${PROMETHEUS_SCHEME}:${prom_pod}:9090/proxy${api_path}"
    if response=$(_prometheus_run_with_timeout 15 kubectl get --raw "${proxy_path}" 2>/dev/null); then
        printf '%s\n' "${response}"
        return 0
    fi
    return 1
}
