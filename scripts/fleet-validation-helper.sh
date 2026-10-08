#!/usr/bin/env bash
# Run an existing scenario validator against a fleet hub/spoke pair.
# Pipeline and monitoring queries default to the hub; commands carrying a
# scenario workload namespace are sent explicitly to the spoke.

_FLEET_VALIDATION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fleet-helper.sh
source "${_FLEET_VALIDATION_DIR}/fleet-helper.sh"

fleet_validation_set_workload_namespaces() {
    FLEET_VALIDATION_WORKLOAD_NAMESPACES=("$@")
}

fleet_validation_is_workload_namespace() {
    local namespace="$1"
    local workload_namespace
    for workload_namespace in "${FLEET_VALIDATION_WORKLOAD_NAMESPACES[@]}"; do
        [ "$namespace" = "$workload_namespace" ] && return 0
    done
    return 1
}

# Validation scripts use plain kubectl. Keep that API intact while routing by
# the explicit namespace argument present on workload assertions/mutations.
kubectl() {
    local namespace=""
    local previous=""
    local resource=""
    local arg
    for arg in "$@"; do
        if [ "$previous" = "-n" ] || [ "$previous" = "--namespace" ]; then
            namespace="$arg"
        elif [[ "$arg" == --namespace=* ]]; then
            namespace="${arg#--namespace=}"
        fi
        if [ "$previous" = "get" ] && [[ "$arg" != -* ]]; then
            resource="$arg"
        fi
        previous="$arg"
    done

    # Kubernaut 1.6 moved AIAnalysis results under rcaResult and RR outcome
    # under completionStatus. Keep older scenario validators working while
    # routing them to the RC19 schema in Fleet mode.
    local normalized_args=()
    for arg in "$@"; do
        case "$resource" in
            aianalysis|aianalyses|aa)
                arg="${arg//.status.selectedWorkflow/.status.rcaResult.selectedWorkflow}"
                arg="${arg//.status.rootCauseAnalysis/.status.rcaResult.rootCauseAnalysis}"
                ;;
            remediationrequest|remediationrequests|rr)
                arg="${arg//.status.outcome/.status.completionStatus.outcome}"
                ;;
        esac
        normalized_args+=("$arg")
    done

    if fleet_validation_is_workload_namespace "$namespace" || {
        [ "${FLEET_VALIDATION_CLUSTER_SCOPED_WORKLOAD:-false}" = true ] &&
        [[ "$resource" =~ ^nodes?$ ]];
    }; then
        command kubectl --kubeconfig="${SPOKE_KUBECONFIG}" "${normalized_args[@]}"
    else
        command kubectl --kubeconfig="${HUB_KUBECONFIG}" "${normalized_args[@]}"
    fi
}

# Helm-backed workload assertions need the same spoke routing as kubectl. Most
# validators use kubectl, but Helm-managed scenarios also inspect release
# status/history after the control-plane pipeline completes.
helm() {
    local namespace=""
    local previous=""
    local has_kubeconfig=false
    local arg

    for arg in "$@"; do
        if [ "$previous" = "-n" ] || [ "$previous" = "--namespace" ]; then
            namespace="$arg"
        elif [[ "$arg" == --namespace=* ]]; then
            namespace="${arg#--namespace=}"
        elif [ "$previous" = "--kubeconfig" ] || [[ "$arg" == --kubeconfig=* ]]; then
            has_kubeconfig=true
        fi
        previous="$arg"
    done

    if [ "$has_kubeconfig" = true ]; then
        command helm "$@"
    elif fleet_validation_is_workload_namespace "$namespace"; then
        command helm --kubeconfig="${SPOKE_KUBECONFIG}" "$@"
    else
        command helm --kubeconfig="${HUB_KUBECONFIG}" "$@"
    fi
}

fleet_validate_local() {
    local validation_script="$1"
    shift

    fleet_initialize_targeting "$@"

    local validation_args=()
    local arg
    for arg in "$@"; do
        [ "$arg" = "--fleet" ] || validation_args+=("$arg")
    done

    # The platform and Alertmanager defaults must describe the hub, not the
    # shell's ambient or previously exported spoke values.
    unset PLATFORM MONITORING_NS ALERTMANAGER_POD
    # validation-helper.sh sources platform-helper.sh. When platform-helper.sh
    # is sourced in a non-TTY it normally re-execs $0 through stdbuf; here $0
    # is the fleet wrapper, and the local validator's --fleet dispatch flag has
    # already been consumed. Mark line buffering as handled so that nested
    # source does not re-exec the wrapper without --fleet (which otherwise
    # causes a silent early exit before any assertions run).
    export _KUBERNAUT_LINEBUF=1
    # shellcheck source=validation-helper.sh
    source "$validation_script" "${validation_args[@]}"
}
