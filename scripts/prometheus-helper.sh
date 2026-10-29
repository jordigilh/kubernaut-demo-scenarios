#!/usr/bin/env bash
# Shared Prometheus client configuration for in-pod queries.
# rc28 serves Prometheus over HTTPS; older demo stacks may still expose HTTP.

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

# Detect the target's Prometheus scheme and prepare the client CA/config.
# Transport failures remain retryable; HTTP is selected only after every CA
# probe succeeds and reports that the file is absent.
prometheus_prepare_connection() {
    local prom_namespace="${1:?prometheus_prepare_connection requires a namespace}"
    local prom_pod="${2:?prometheus_prepare_connection requires a pod}"
    local target="${prom_namespace}/${prom_pod}"

    if [ "${PROMETHEUS_CONNECTION_TARGET}" = "${target}" ] && \
        [ -n "${PROMETHEUS_SCHEME}" ]; then
        return 0
    fi

    local ca_file=""
    local candidate
    # Keep the rc28 paths first, then support the TLS mounts used by the
    # Alertmanager/Prometheus demo variants and OpenShift monitoring stacks.
    for candidate in \
        /etc/prometheus/web_config/secret/monitoring-tls-key/ca.crt \
        /etc/prometheus/web_config/secret/monitoring-tls-cert/ca.crt \
        /etc/monitoring-tls/ca.crt \
        /etc/tls-ca/ca.crt \
        /etc/prometheus/certs/ca.crt \
        /etc/prometheus/configmaps/serving-certs-ca-bundle/service-ca.crt \
        /etc/prometheus/configmaps/serving-certs-ca-bundle/ca-bundle.crt; do
        local probe_result
        if ! probe_result=$(_prometheus_run_with_timeout 10 kubectl exec \
            -n "${prom_namespace}" "${prom_pod}" -c prometheus -- \
            sh -c 'if [ -f "$1" ]; then printf present; else printf absent; fi' -- \
            "${candidate}" 2>/dev/null); then
            echo "WARNING: could not inspect Prometheus CA mount ${candidate} in ${prom_namespace}/${prom_pod}; retrying discovery." >&2
            return 1
        fi
        if [ "${probe_result}" = "present" ]; then
            ca_file="${candidate}"
            break
        fi
    done

    if [ -n "${ca_file}" ]; then
        # /tmp is read-only in the rc28 Prometheus container; /dev/shm is
        # writable and is appropriate for this short-lived client config.
        local config_path="${PROMETHEUS_HTTP_CONFIG_PATH:-/dev/shm/kubernaut-prometheus-http-config.yml}"
        if ! _prometheus_run_with_timeout 10 kubectl exec \
            -n "${prom_namespace}" "${prom_pod}" -c prometheus -- sh -c \
            "printf '%s\\n' 'tls_config:' '  ca_file: ${ca_file}' > '${config_path}'"; then
            echo "ERROR: could not create the Prometheus TLS client config in ${prom_namespace}/${prom_pod}." >&2
            return 1
        fi
        PROMETHEUS_CONNECTION_TARGET="${target}"
        PROMETHEUS_CA_FILE="${ca_file}"
        PROMETHEUS_SCHEME="https"
        PROMETHEUS_HTTP_CONFIG_FILE="${config_path}"
    else
        # Older demo stacks without a mounted CA serve the local endpoint over
        # HTTP. This is the only path where HTTP is allowed.
        PROMETHEUS_CONNECTION_TARGET="${target}"
        PROMETHEUS_CA_FILE=""
        PROMETHEUS_HTTP_CONFIG_FILE=""
        PROMETHEUS_SCHEME="http"
    fi
}

# Read a Prometheus HTTP API path from inside the Prometheus pod. This keeps
# rule/API checks on the same TLS-aware path as PromQL queries and avoids a
# host port-forward with an unknown local certificate trust chain.
prometheus_api_get() {
    local prom_namespace="${1:?prometheus_api_get requires a namespace}"
    local prom_pod="${2:?prometheus_api_get requires a pod}"
    local api_path="${3:?prometheus_api_get requires an API path}"
    prometheus_prepare_connection "${prom_namespace}" "${prom_pod}" || return 1

    local url="${PROMETHEUS_SCHEME}://localhost:9090${api_path}"
    local curl_args=(-sf --connect-timeout 5 "${url}")
    if [ "${PROMETHEUS_SCHEME}" = "https" ]; then
        curl_args+=(--cacert "${PROMETHEUS_CA_FILE}")
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
        if kubectl exec -n "${prom_namespace}" "${prom_pod}" -c prometheus -- \
            wget --help 2>&1 | grep -q -- '--ca-certificate'; then
            wget_args+=(--ca-certificate="${PROMETHEUS_CA_FILE}")
        else
            # BusyBox wget in the rc28 image cannot load a custom CA. The
            # request remains HTTPS and is limited to the loopback endpoint;
            # promtool (used for PromQL) still verifies with the mounted CA.
            wget_args+=(--no-check-certificate)
        fi
    fi
    if response=$(_prometheus_run_with_timeout 15 kubectl exec \
        -n "${prom_namespace}" "${prom_pod}" -c prometheus -- \
        wget "${wget_args[@]}" 2>/dev/null); then
        printf '%s\n' "${response}"
        return 0
    fi
    return 1
}
