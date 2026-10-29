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

    AMTOOL_CONNECTION_TARGET="${am_namespace}/${am_pod}"

    if kubectl exec -n "${am_namespace}" "${am_pod}" -- \
        test -f /etc/monitoring-tls/ca.crt >/dev/null 2>&1; then
        kubectl exec -n "${am_namespace}" "${am_pod}" -- sh -c \
            "printf '%s\\n' 'tls_config:' '  ca_file: /etc/monitoring-tls/ca.crt' > '${config_path}'"
        AMTOOL_CONNECTION_ARGS=(
            "--alertmanager.url=https://localhost:9093"
            "--http.config.file=${config_path}"
        )
    elif kubectl exec -n "${am_namespace}" "${am_pod}" -- \
        test -f /etc/tls-ca/ca.crt >/dev/null 2>&1; then
        kubectl exec -n "${am_namespace}" "${am_pod}" -- sh -c \
            "printf '%s\\n' 'tls_config:' '  ca_file: /etc/tls-ca/ca.crt' > '${config_path}'"
        AMTOOL_CONNECTION_ARGS=(
            "--alertmanager.url=https://localhost:9093"
            "--http.config.file=${config_path}"
        )
    else
        # Preserve compatibility with older demo stacks that serve amtool over
        # plain HTTP and do not mount a CA bundle.
        AMTOOL_CONNECTION_ARGS=("--alertmanager.url=http://localhost:9093")
    fi
    AMTOOL_CONNECTION_READY=1
}
