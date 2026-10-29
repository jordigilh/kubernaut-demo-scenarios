#!/usr/bin/env bash
# Shared Alertmanager client configuration for demo helpers.
# Alertmanager is HTTPS in the rc28 demo stack; older setups may still expose
# the local amtool endpoint over HTTP.

AMTOOL_CONNECTION_READY="${AMTOOL_CONNECTION_READY:-0}"
AMTOOL_CONNECTION_ARGS=()
AMTOOL_CONNECTION_TARGET="${AMTOOL_CONNECTION_TARGET:-}"

# Detect the Alertmanager scheme/CA for a specific pod and cache only a usable
# connection configuration for that namespace/pod target.
amtool_prepare_connection() {
    local am_namespace="${1:?amtool_prepare_connection requires a namespace}"
    local am_pod="${2:?amtool_prepare_connection requires a pod}"
    local config_path="/tmp/kubernaut-amtool-http-config.yml"

    if [ "${AMTOOL_CONNECTION_READY}" = "1" ] && \
        [ "${AMTOOL_CONNECTION_TARGET}" = "${am_namespace}/${am_pod}" ] && \
        [ "${#AMTOOL_CONNECTION_ARGS[@]}" -gt 0 ]; then
        return 0
    fi

    # Clear stale state before probing a new target. A failed exec must not
    # inherit or publish an HTTP fallback for an HTTPS-only pod.
    AMTOOL_CONNECTION_READY=0
    AMTOOL_CONNECTION_TARGET=""
    AMTOOL_CONNECTION_ARGS=()

    local ca_file=""
    local candidate probe_result
    for candidate in /etc/monitoring-tls/ca.crt /etc/tls-ca/ca.crt; do
        if ! probe_result=$(kubectl exec -n "${am_namespace}" "${am_pod}" -- \
            sh -c 'if [ -f "$1" ]; then printf present; else printf absent; fi' -- \
            "${candidate}" 2>/dev/null); then
            echo "WARNING: could not inspect Alertmanager CA mount ${candidate} in ${am_namespace}/${am_pod}; retrying discovery." >&2
            return 1
        fi
        if [ "${probe_result}" = "present" ]; then
            ca_file="${candidate}"
            break
        fi
    done

    if [ -n "${ca_file}" ]; then
        if ! kubectl exec -n "${am_namespace}" "${am_pod}" -- sh -c \
            "printf '%s\\n' 'tls_config:' '  ca_file: ${ca_file}' > '${config_path}'"; then
            echo "WARNING: could not create Alertmanager TLS client config in ${am_namespace}/${am_pod}; retrying discovery." >&2
            return 1
        fi
        AMTOOL_CONNECTION_ARGS=(
            "--alertmanager.url=https://localhost:9093"
            "--http.config.file=${config_path}"
        )
    else
        # Preserve compatibility with older demo stacks that serve amtool over
        # plain HTTP and do not mount a CA bundle.
        AMTOOL_CONNECTION_ARGS=("--alertmanager.url=http://localhost:9093")
    fi
    AMTOOL_CONNECTION_TARGET="${am_namespace}/${am_pod}"
    AMTOOL_CONNECTION_READY=1
}
