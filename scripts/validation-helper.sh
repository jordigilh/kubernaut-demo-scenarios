#!/usr/bin/env bash
# Shared validation helpers for demo scenario validate.sh scripts and VHS tapes.
# Source this from validate.sh or .tape hidden blocks:
#   source "$(dirname "$0")/../../scripts/validation-helper.sh"
#
# All display functions produce clean terminal output suitable for both
# interactive use and VHS recordings. Functions are individually callable:
#   source validation-helper.sh && show_ai_analysis demo-hpa

# ── Color support ────────────────────────────────────────────────────────────
# Respects NO_COLOR (https://no-color.org/) and --no-color flag.
_VALIDATION_NO_COLOR="${NO_COLOR:-}"

_c_reset=""
_c_green=""
_c_red=""
_c_blue=""
_c_cyan=""
_c_yellow=""
_c_bold=""
_c_dim=""

_init_colors() {
    if [ -n "$_VALIDATION_NO_COLOR" ]; then return; fi
    if [ ! -t 1 ]; then return; fi  # not a terminal
    _c_reset=$'\033[0m'
    _c_green=$'\033[32m'
    _c_red=$'\033[31m'
    _c_blue=$'\033[34m'
    _c_cyan=$'\033[36m'
    _c_yellow=$'\033[33m'
    _c_bold=$'\033[1m'
    _c_dim=$'\033[2m'
}
_init_colors

# ── Assertion tracking ───────────────────────────────────────────────────────
_ASSERT_PASS=0
_ASSERT_FAIL=0
_ASSERT_TOTAL=0

# ── Utilities ────────────────────────────────────────────────────────────────

_ts() {
    date '+%H:%M:%S'
}

log_phase() {
    printf '%s[%s]%s %s\n' "$_c_dim" "$(_ts)" "$_c_reset" "$1"
}

log_transition() {
    printf '%s[%s]%s %sPhase: %s -> %s%s\n' \
        "$_c_dim" "$(_ts)" "$_c_reset" "$_c_blue" "$1" "$2" "$_c_reset"
}

log_info() {
    printf '           %s\n' "$1"
}

log_success() {
    printf '%s[%s]%s %s%s%s\n' "$_c_dim" "$(_ts)" "$_c_reset" "$_c_green" "$1" "$_c_reset"
}

log_error() {
    printf '%s[%s]%s %s%s%s\n' "$_c_dim" "$(_ts)" "$_c_reset" "$_c_red" "$1" "$_c_reset"
}

log_warn() {
    printf '%s[%s]%s %s%s%s\n' "$_c_dim" "$(_ts)" "$_c_reset" "$_c_yellow" "$1" "$_c_reset"
}

# ── CRD namespace ────────────────────────────────────────────────────────────
# Pipeline CRDs (RR, SP, AA, WFE, EA, RAR) are created in the platform
# namespace, not in the scenario namespace. The scenario namespace is only
# used for workload assertions (pods, HPA, deployments, etc.).
PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

# ── Platform-aware monitoring defaults ───────────────────────────────────────
# Auto-detect PLATFORM when not already set (e.g. validate.sh invoked
# standalone without run.sh having sourced platform-helper.sh first — #125).
if [ -z "${PLATFORM:-}" ]; then
    _VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=platform-helper.sh
    source "${_VH_DIR}/platform-helper.sh" 2>/dev/null || true
    unset _VH_DIR
fi
if [ "${PLATFORM:-}" = "ocp" ]; then
    MONITORING_NS="${MONITORING_NS:-openshift-monitoring}"
    ALERTMANAGER_POD="${ALERTMANAGER_POD:-alertmanager-main-0}"
else
    MONITORING_NS="${MONITORING_NS:-monitoring}"
    ALERTMANAGER_POD="${ALERTMANAGER_POD:-alertmanager-kube-prometheus-stack-alertmanager-0}"
fi

# ── CRD field accessors ─────────────────────────────────────────────────────
# Thin wrappers over kubectl jsonpath. Return empty string on missing fields.
# $1 = scenario namespace (used to find the RR by target namespace label)
# When multiple RRs exist, we filter by the most recent one targeting $1.

_find_rr_name() {
    local target_ns="$1"
    # Find the most recent RR whose signalLabels.namespace exactly matches the
    # target namespace.  Uses awk instead of grep to avoid substring collisions
    # (e.g. "demo-crashloop" matching "demo-crashloop-helm") — #148.
    kubectl get remediationrequests -n "$PLATFORM_NS" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
        | awk -F'\t' -v ns="$target_ns" '$2 == ns { print $1 }' | tail -1
}

get_rr_phase() {
    local rr_name
    rr_name=$(_find_rr_name "$1")
    if [ -z "$rr_name" ]; then echo ""; return; fi
    kubectl get remediationrequests "$rr_name" -n "$PLATFORM_NS" \
        -o jsonpath='{.status.overallPhase}' 2>/dev/null || echo ""
}

get_rr_outcome() {
    local rr_name
    rr_name=$(_find_rr_name "$1")
    if [ -z "$rr_name" ]; then echo ""; return; fi
    kubectl get remediationrequests "$rr_name" -n "$PLATFORM_NS" \
        -o jsonpath='{.status.outcome}' 2>/dev/null || echo ""
}

get_rr_name() {
    _find_rr_name "$1"
}

get_sp_phase() {
    local rr_name
    rr_name=$(_find_rr_name "$1")
    if [ -z "$rr_name" ]; then echo ""; return; fi
    local sp_name="sp-${rr_name}"
    kubectl get signalprocessings "$sp_name" -n "$PLATFORM_NS" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo ""
}

get_aa_phase() {
    local rr_name
    rr_name=$(_find_rr_name "$1")
    if [ -z "$rr_name" ]; then echo ""; return; fi
    local aa_name="ai-${rr_name}"
    kubectl get aianalyses "$aa_name" -n "$PLATFORM_NS" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo ""
}

get_wfe_phase() {
    local rr_name
    rr_name=$(_find_rr_name "$1")
    if [ -z "$rr_name" ]; then echo ""; return; fi
    local wfe_name="we-${rr_name}"
    kubectl get workflowexecutions "$wfe_name" -n "$PLATFORM_NS" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo ""
}

get_ea_phase() {
    local rr_name
    rr_name=$(_find_rr_name "$1")
    if [ -z "$rr_name" ]; then echo ""; return; fi
    local ea_name="ea-${rr_name}"
    kubectl get effectivenessassessments "$ea_name" -n "$PLATFORM_NS" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo ""
}

get_rar_count() {
    kubectl get remediationapprovalrequests -n "$PLATFORM_NS" --no-headers 2>/dev/null | wc -l | tr -d ' '
}

# ── Wait functions ───────────────────────────────────────────────────────────

# Wait for a Prometheus alert to appear in AlertManager.
# Args: $1=alert_name $2=namespace $3=timeout_seconds (default 300)
wait_for_alert() {
    local alert_name="$1"
    local namespace="$2"
    local timeout="${3:-300}"
    local am_pod="${ALERTMANAGER_POD}"
    local elapsed=0
    local interval=10

    log_phase "Waiting for ${_c_cyan}${alert_name}${_c_reset} alert (timeout: ${timeout}s)..."

    local ns_filter=()
    if [ -n "$namespace" ]; then
        ns_filter=("namespace=${namespace}")
    fi

    while [ "$elapsed" -lt "$timeout" ]; do
        local count
        count=$(kubectl exec -n "${MONITORING_NS}" "$am_pod" -- \
            amtool alert query "alertname=${alert_name}" "${ns_filter[@]}" \
            --alertmanager.url=http://localhost:9093 \
            --output=json 2>/dev/null \
            | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

        if [ "$count" != "0" ] && [ "$count" != "" ]; then
            log_success "Alert ${alert_name} fired in AlertManager"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Timed out waiting for alert ${alert_name} after ${timeout}s"
    return 1
}

# Wait for at least one RemediationRequest to exist in the namespace.
# Args: $1=namespace $2=timeout_seconds (default 120)
wait_for_rr() {
    local target_ns="$1"
    local timeout="${2:-240}"
    local elapsed=0
    local interval=5

    log_phase "Waiting for RemediationRequest (target: ${target_ns})..."

    while [ "$elapsed" -lt "$timeout" ]; do
        local rr_name
        rr_name=$(_find_rr_name "$target_ns")
        if [ -n "$rr_name" ]; then
            local phase
            phase=$(get_rr_phase "$target_ns")
            log_success "RemediationRequest ${rr_name} created -> Phase: ${phase}"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Timed out waiting for RemediationRequest after ${timeout}s"
    return 1
}

# Wait until all alerts for a namespace have cleared from AlertManager.
# Useful before re-running a scenario to avoid stale alerts causing the
# Gateway to drop signals with "Owner resolution failed" (#193).
# Args: $1=namespace $2=timeout_seconds (default 300)
wait_for_alerts_cleared() {
    local namespace="$1"
    local timeout="${2:-300}"
    local am_pod="${ALERTMANAGER_POD}"
    local elapsed=0
    local interval=10

    local count
    count=$(kubectl exec -n "${MONITORING_NS}" "$am_pod" -- \
        amtool alert query "namespace=${namespace}" \
        --alertmanager.url=http://localhost:9093 \
        --output=json 2>/dev/null \
        | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [ "$count" = "0" ] || [ -z "$count" ]; then
        return 0
    fi

    log_phase "Waiting for ${count} stale alert(s) in namespace ${namespace} to clear (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        count=$(kubectl exec -n "${MONITORING_NS}" "$am_pod" -- \
            amtool alert query "namespace=${namespace}" \
            --alertmanager.url=http://localhost:9093 \
            --output=json 2>/dev/null \
            | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

        if [ "$count" = "0" ] || [ -z "$count" ]; then
            log_success "All alerts cleared for namespace ${namespace}"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_warn "Timed out waiting for alerts to clear in ${namespace} after ${timeout}s (${count} remaining)"
    return 1
}

# Pre-run cleanup: delete a demo namespace and wait for its stale alerts
# to drain from AlertManager before starting a new scenario run.
# Prevents the Gateway from dropping signals for recreated resources (#193).
# Args: $1=namespace $2=alert_drain_timeout (default 180)
ensure_clean_slate() {
    local namespace="$1"
    local timeout="${2:-180}"

    if kubectl get namespace "$namespace" &>/dev/null; then
        log_phase "Cleaning up existing namespace ${namespace}..."
        kubectl delete namespace "$namespace" --wait=true --timeout=60s 2>/dev/null || true

        log_phase "Waiting for namespace ${namespace} to be fully removed..."
        local ns_elapsed=0
        while kubectl get namespace "$namespace" &>/dev/null && [ "$ns_elapsed" -lt 90 ]; do
            sleep 5
            ns_elapsed=$((ns_elapsed + 5))
        done

        wait_for_alerts_cleared "$namespace" "$timeout" || true
    fi

    local rr_names
    rr_names=$(kubectl get remediationrequests -n "$PLATFORM_NS" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.signalLabels.namespace}{"\n"}{end}' 2>/dev/null \
        | awk -F'\t' -v ns="$namespace" '$2 == ns { print $1 }')
    if [ -n "$rr_names" ]; then
        log_phase "Deleting stale RRs for namespace ${namespace}..."
        echo "$rr_names" | while IFS= read -r rr; do
            kubectl delete remediationrequest "$rr" -n "$PLATFORM_NS" --ignore-not-found 2>/dev/null || true
        done
    fi
}

# Wait for RR to reach a specific phase (or terminal).
# Args: $1=namespace $2=target_phase $3=timeout (default 600)
wait_for_rr_phase() {
    local namespace="$1"
    local target="$2"
    local timeout="${3:-600}"
    local elapsed=0
    local interval=10

    while [ "$elapsed" -lt "$timeout" ]; do
        local phase
        phase=$(get_rr_phase "$namespace")
        if [ "$phase" = "$target" ]; then
            return 0
        fi
        # Terminal states -- stop waiting
        case "$phase" in
            Completed|Failed|TimedOut|Cancelled|Skipped)
                return 0
                ;;
        esac
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

# ── Display functions ────────────────────────────────────────────────────────
# Designed for both validate.sh progress output and VHS tape visibility.

show_alert() {
    local alert_name="$1"
    local namespace="${2:-}"
    local am_pod="${ALERTMANAGER_POD}"

    local query_args=("alertname=${alert_name}")
    [ -n "$namespace" ] && query_args+=("namespace=${namespace}")

    local alerts_json
    alerts_json=$(kubectl exec -n "${MONITORING_NS}" "$am_pod" -- \
        amtool alert query "${query_args[@]}" \
        --alertmanager.url=http://localhost:9093 \
        --output=json 2>/dev/null || echo "[]")

    python3 -c "
import sys, json
alerts = json.loads('''${alerts_json}''')
for a in alerts:
    labels = a.get('labels', {})
    annots = a.get('annotations', {})
    state = a.get('status', {}).get('state', 'unknown')
    print(f'           Alert: {labels.get(\"alertname\", \"N/A\")} | Severity: {labels.get(\"severity\", \"N/A\")} | Namespace: {labels.get(\"namespace\", \"N/A\")}')
    summary = annots.get('summary', '')
    if summary:
        # Wrap long summaries
        import textwrap
        lines = textwrap.wrap(summary, 70)
        print(f'           Summary: {lines[0]}')
        for line in lines[1:]:
            print(f'                    {line}')
" 2>/dev/null || true
}

show_pipeline_status() {
    printf '\n'
    kubectl get remediationrequests,signalprocessings,aianalyses,workflowexecutions,effectivenessassessments -n "$PLATFORM_NS" 2>/dev/null | sed 's/^/           /'
    printf '\n'
}

# Pretty-print the AI Analysis CRD status fields.
# Callable standalone: source validation-helper.sh && show_ai_analysis NAMESPACE
show_ai_analysis() {
    local target_ns="$1"

    local rr_name aa_name
    rr_name=$(_find_rr_name "$target_ns")
    if [ -z "$rr_name" ]; then
        log_info "(no AIAnalysis found — RR not resolved for ${target_ns})"
        return
    fi
    aa_name="ai-${rr_name}"

    local ns="$PLATFORM_NS"
    local root_cause severity affected_kind affected_name affected_ns
    local confidence workflow_id exec_bundle rationale approval approval_reason

    root_cause=$(kubectl get aianalyses "$aa_name" -n "$ns" -o jsonpath='{.status.rootCause}' 2>/dev/null || true)
    severity=$(kubectl get aianalyses "$aa_name" -n "$ns" -o jsonpath='{.status.rootCauseAnalysis.severity}' 2>/dev/null || true)
    affected_kind=$(kubectl get aianalyses "$aa_name" -n "$ns" -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.kind}' 2>/dev/null || true)
    affected_name=$(kubectl get aianalyses "$aa_name" -n "$ns" -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.name}' 2>/dev/null || true)
    affected_ns=$(kubectl get aianalyses "$aa_name" -n "$ns" -o jsonpath='{.status.rootCauseAnalysis.remediationTarget.namespace}' 2>/dev/null || true)
    confidence=$(kubectl get aianalyses "$aa_name" -n "$ns" -o jsonpath='{.status.selectedWorkflow.confidence}' 2>/dev/null || true)
    workflow_id=$(kubectl get aianalyses "$aa_name" -n "$ns" -o jsonpath='{.status.selectedWorkflow.workflowId}' 2>/dev/null || true)
    exec_bundle=$(kubectl get aianalyses "$aa_name" -n "$ns" -o jsonpath='{.status.selectedWorkflow.executionBundle}' 2>/dev/null || true)
    rationale=$(kubectl get aianalyses "$aa_name" -n "$ns" -o jsonpath='{.status.selectedWorkflow.rationale}' 2>/dev/null || true)
    approval=$(kubectl get aianalyses "$aa_name" -n "$ns" -o jsonpath='{.status.approvalRequired}' 2>/dev/null || true)
    approval_reason=$(kubectl get aianalyses "$aa_name" -n "$ns" -o jsonpath='{.status.approvalReason}' 2>/dev/null || true)

    printf '\n'
    printf '           %s%sAI Analysis%s\n' "$_c_bold" "$_c_cyan" "$_c_reset"
    printf '           %s──────────────────────────────────────────%s\n' "$_c_dim" "$_c_reset"
    printf '           Root Cause:    %s\n' "${root_cause:-N/A}"
    printf '           Severity:      %s\n' "${severity:-unknown}"
    if [ -n "$affected_kind" ]; then
        printf '           Target:        %s/%s (ns: %s)\n' "$affected_kind" "$affected_name" "$affected_ns"
    fi
    printf '           Workflow:      %s (%s)\n' "${workflow_id:-N/A}" "${exec_bundle:-N/A}"
    printf '           Confidence:    %s\n' "${confidence:-N/A}"
    if [ -n "$rationale" ]; then
        # Wrap long rationale text
        local first_line rest
        first_line=$(echo "$rationale" | head -c 70)
        if [ ${#rationale} -gt 70 ]; then
            printf '           Rationale:     %s...\n' "$first_line"
        else
            printf '           Rationale:     %s\n' "$rationale"
        fi
    fi
    if [ "$approval" = "true" ]; then
        printf '           Approval:      %srequired%s (%s)\n' "$_c_yellow" "$_c_reset" "${approval_reason:-policy match}"
    else
        printf '           Approval:      %snot required%s\n' "$_c_green" "$_c_reset"
    fi
    printf '\n'
}

show_wfe_progress() {
    local target_ns="$1"

    local rr_name wfe_name phase
    rr_name=$(_find_rr_name "$target_ns")
    if [ -z "$rr_name" ]; then
        log_info "(no WorkflowExecution found — RR not resolved for ${target_ns})"
        return
    fi
    wfe_name="we-${rr_name}"

    phase=$(kubectl get workflowexecutions "$wfe_name" -n "$PLATFORM_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    local completed total duration
    completed=$(kubectl get workflowexecutions "$wfe_name" -n "$PLATFORM_NS" -o jsonpath='{.status.executionStatus.completedTasks}' 2>/dev/null)
    total=$(kubectl get workflowexecutions "$wfe_name" -n "$PLATFORM_NS" -o jsonpath='{.status.executionStatus.totalTasks}' 2>/dev/null)
    duration=$(kubectl get workflowexecutions "$wfe_name" -n "$PLATFORM_NS" -o jsonpath='{.status.duration}' 2>/dev/null)

    printf '           WFE Phase: %s' "$phase"
    if [ -n "$completed" ] && [ -n "$total" ]; then
        printf ' (%s/%s tasks)' "$completed" "$total"
    fi
    if [ -n "$duration" ]; then
        printf ' [%s]' "$duration"
    fi
    printf '\n'
}

# Pretty-print the EffectivenessAssessment status.
# Callable standalone: source validation-helper.sh && show_effectiveness NAMESPACE
show_effectiveness() {
    local target_ns="$1"

    local rr_name ea_name
    rr_name=$(_find_rr_name "$target_ns")
    if [ -z "$rr_name" ]; then
        log_info "(no EffectivenessAssessment found — RR not resolved for ${target_ns})"
        return
    fi
    ea_name="ea-${rr_name}"

    local phase reason message alert_score health_score metrics_score
    phase=$(kubectl get effectivenessassessments "$ea_name" -n "$PLATFORM_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
    reason=$(kubectl get effectivenessassessments "$ea_name" -n "$PLATFORM_NS" -o jsonpath='{.status.assessmentReason}' 2>/dev/null)
    message=$(kubectl get effectivenessassessments "$ea_name" -n "$PLATFORM_NS" -o jsonpath='{.status.message}' 2>/dev/null)
    alert_score=$(kubectl get effectivenessassessments "$ea_name" -n "$PLATFORM_NS" -o jsonpath='{.status.components.alertScore}' 2>/dev/null)
    health_score=$(kubectl get effectivenessassessments "$ea_name" -n "$PLATFORM_NS" -o jsonpath='{.status.components.healthScore}' 2>/dev/null)
    metrics_score=$(kubectl get effectivenessassessments "$ea_name" -n "$PLATFORM_NS" -o jsonpath='{.status.components.metricsScore}' 2>/dev/null)

    printf '\n'
    printf '           %s%sEffectiveness Assessment%s\n' "$_c_bold" "$_c_cyan" "$_c_reset"
    printf '           %s──────────────────────────────────────────%s\n' "$_c_dim" "$_c_reset"
    printf '           Phase:         %s\n' "${phase:-Pending}"
    printf '           Reason:        %s\n' "${reason:-N/A}"
    if [ -n "$message" ]; then
        printf '           Message:       %s\n' "$message"
    fi
    printf '           Alert Score:   %s\n' "${alert_score:-pending}"
    printf '           Health Score:  %s\n' "${health_score:-pending}"
    printf '           Metrics Score: %s\n' "${metrics_score:-pending}"
    printf '\n'
}

# ── Notification display ──────────────────────────────────────────────────────
# Show NotificationRequest CRDs inline during pipeline polling.
# Graceful no-op when no NR exists (e.g., notifications disabled).

_find_nr_for_rr() {
    local rr_name="$1" pattern="${2:-}"
    kubectl get notificationrequests -n "$PLATFORM_NS" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.remediationRequestRef.name}{"\n"}{end}' 2>/dev/null \
        | { grep "$rr_name" || true; } \
        | while IFS=$'\t' read -r nr_name nr_rr; do
            if [ -n "$pattern" ]; then
                [[ "$nr_name" == *"$pattern"* ]] && echo "$nr_name"
            else
                echo "$nr_name"
            fi
        done
}

_display_nr() {
    local nr_name="$1"
    local subj body prio nr_type phase

    subj=$(kubectl get notificationrequest "$nr_name" -n "$PLATFORM_NS" \
        -o jsonpath='{.spec.subject}' 2>/dev/null || true)
    body=$(kubectl get notificationrequest "$nr_name" -n "$PLATFORM_NS" \
        -o jsonpath='{.spec.body}' 2>/dev/null || true)
    prio=$(kubectl get notificationrequest "$nr_name" -n "$PLATFORM_NS" \
        -o jsonpath='{.spec.priority}' 2>/dev/null || true)
    nr_type=$(kubectl get notificationrequest "$nr_name" -n "$PLATFORM_NS" \
        -o jsonpath='{.spec.type}' 2>/dev/null || true)
    phase=$(kubectl get notificationrequest "$nr_name" -n "$PLATFORM_NS" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)

    [ -z "$subj" ] && [ -z "$body" ] && return

    printf '\n'
    printf '           %s%sNotification%s  %s[%s | %s | %s]%s\n' \
        "$_c_bold" "$_c_yellow" "$_c_reset" \
        "$_c_dim" "${nr_type:-notification}" "${prio:-normal}" "${phase:-Pending}" "$_c_reset"
    printf '           %s──────────────────────────────────────────%s\n' "$_c_dim" "$_c_reset"
    if [ -n "$subj" ]; then
        printf '           %s\n' "$subj"
        printf '           %s──────────────────────────────────────────%s\n' "$_c_dim" "$_c_reset"
    fi
    if [ -n "$body" ]; then
        echo "$body" | fold -s -w 70 | while IFS= read -r line; do
            printf '           %s\n' "$line"
        done
    fi
    printf '\n'
}

show_approval_notification() {
    local target_ns="$1"
    local rr_name
    rr_name=$(_find_rr_name "$target_ns")
    [ -z "$rr_name" ] && return

    local nr_name
    nr_name=$(_find_nr_for_rr "$rr_name" "rar" | head -1) || true
    if [ -z "$nr_name" ]; then
        nr_name=$(_find_nr_for_rr "$rr_name" | head -1) || true
    fi
    [ -z "$nr_name" ] && return
    _display_nr "$nr_name"
}

show_outcome_notification() {
    local target_ns="$1"
    local rr_name
    rr_name=$(_find_rr_name "$target_ns")
    [ -z "$rr_name" ] && return

    local all_nrs last_nr
    all_nrs=$(_find_nr_for_rr "$rr_name") || true
    last_nr=$(echo "$all_nrs" | tail -1)
    [ -z "$last_nr" ] && return

    local first_nr
    first_nr=$(echo "$all_nrs" | head -1)
    [ "$last_nr" = "$first_nr" ] && return

    _display_nr "$last_nr"
}

# ── Approval ─────────────────────────────────────────────────────────────────

# Auto-approve the RAR for a specific RR.
# Waits up to 30s for the RAR to be created (RO creates it asynchronously
# after the RR transitions to AwaitingApproval).
# Args: $1=rr_name (required) — derives RAR name as rar-{rr_name}
auto_approve_rar() {
    local rr_name="${1:-}"
    local rar_wait_timeout=30
    local rar_wait_elapsed=0

    if [ -z "$rr_name" ]; then
        log_warn "auto_approve_rar requires an RR name argument"
        return 1
    fi

    local rar_name="rar-${rr_name}"

    log_phase "Waiting for RAR ${rar_name} to be created..."
    while [ "$rar_wait_elapsed" -lt "$rar_wait_timeout" ]; do
        if kubectl get remediationapprovalrequest "$rar_name" -n "$PLATFORM_NS" &>/dev/null; then
            break
        fi
        sleep 2
        rar_wait_elapsed=$((rar_wait_elapsed + 2))
    done

    if ! kubectl get remediationapprovalrequest "$rar_name" -n "$PLATFORM_NS" &>/dev/null; then
        log_warn "RAR ${rar_name} not found after ${rar_wait_timeout}s"
        return 1
    fi

    if ! kubectl patch remediationapprovalrequest "$rar_name" -n "$PLATFORM_NS" \
        --type=merge --subresource=status \
        -p '{"status":{"decision":"Approved","decidedBy":"validate.sh","decisionMessage":"Auto-approved by validation script"}}' \
        2>/dev/null; then
        log_warn "Failed to patch RAR ${rar_name}, will retry"
        return 1
    fi

    log_success "Approved RAR ${rar_name}"
    return 0
}

# ── Main pipeline poller ─────────────────────────────────────────────────────
# Polls RR overallPhase, prints transitions, shows AI analysis and WFE inline.
#
# Args: $1=target_namespace $2=timeout (default 600) $3=--auto-approve|--interactive (default --auto-approve)
poll_pipeline() {
    local target_ns="$1"
    local timeout="${2:-600}"
    local approve_mode="${3:---auto-approve}"
    local elapsed=0
    local interval=10
    local prev_phase=""
    local aa_shown=false
    local ea_shown=false

    log_phase "Polling pipeline (timeout: ${timeout}s, approval: ${approve_mode})..."

    while [ "$elapsed" -lt "$timeout" ]; do
        local phase
        phase=$(get_rr_phase "$target_ns")

        # Print phase transitions
        if [ "$phase" != "$prev_phase" ] && [ -n "$phase" ]; then
            if [ -n "$prev_phase" ]; then
                log_transition "$prev_phase" "$phase"
            fi

            case "$phase" in
                Analyzing)
                    log_phase "AI Analysis in progress..."
                    ;;
                AwaitingApproval)
                    if [ "$aa_shown" = false ]; then
                        show_ai_analysis "$target_ns" || true
                        aa_shown=true
                    fi
                    show_approval_notification "$target_ns" || true
                    if [ "$approve_mode" != "--auto-approve" ]; then
                        local _hint_rr
                        _hint_rr=$(_find_rr_name "$target_ns")
                        log_warn "Awaiting manual approval. Approve with:"
                        log_info "  kubectl patch rar rar-${_hint_rr} -n $PLATFORM_NS --type=merge --subresource=status -p '{\"status\":{\"decision\":\"Approved\"}}'"
                    fi
                    ;;
                Executing)
                    if [ "$aa_shown" = false ]; then
                        show_ai_analysis "$target_ns" || true
                        aa_shown=true
                    fi
                    log_phase "WorkflowExecution running..."
                    ;;
                Verifying)
                    log_phase "EffectivenessAssessment verification in progress..."
                    if [ -n "${ON_VERIFYING_HOOK:-}" ] && type "$ON_VERIFYING_HOOK" &>/dev/null; then
                        "$ON_VERIFYING_HOOK"
                        ON_VERIFYING_HOOK=""
                    fi
                    ;;
                Completed)
                    if [ "$aa_shown" = false ]; then
                        show_ai_analysis "$target_ns" || true
                        aa_shown=true
                    fi
                    local outcome
                    outcome=$(get_rr_outcome "$target_ns")
                    log_success "Pipeline completed (outcome: ${outcome})"
                    _wait_for_ea "$target_ns"
                    show_outcome_notification "$target_ns" || true
                    return 0
                    ;;
                Failed|TimedOut|Cancelled)
                    log_error "Pipeline terminated with phase: ${phase}"
                    local rr_name block_msg
                    rr_name=$(_find_rr_name "$target_ns")
                    block_msg=$(kubectl get remediationrequests "$rr_name" -n "$PLATFORM_NS" \
                        -o jsonpath='{.status.blockMessage}' 2>/dev/null)
                    if [ -n "$block_msg" ]; then
                        log_info "Block message: $block_msg"
                    fi
                    return 1
                    ;;
                Blocked|Skipped)
                    local rr_name block_reason
                    rr_name=$(_find_rr_name "$target_ns")
                    block_reason=$(kubectl get remediationrequests "$rr_name" -n "$PLATFORM_NS" \
                        -o jsonpath='{.status.blockReason}' 2>/dev/null)
                    log_warn "Pipeline ${phase} (reason: ${block_reason:-unknown})"
                    return 0
                    ;;
            esac

            prev_phase="$phase"
        fi

        # Retry auto-approval on every poll while phase is AwaitingApproval (#115).
        # The display (show_ai_analysis, show_approval_notification) fires once on
        # transition above; the actual approval retries here until it succeeds.
        if [ "$phase" = "AwaitingApproval" ] && [ "$approve_mode" = "--auto-approve" ]; then
            local rr_name rar_decision
            rr_name=$(_find_rr_name "$target_ns")
            if [ -n "$rr_name" ]; then
                rar_decision=$(kubectl get remediationapprovalrequest "rar-${rr_name}" \
                    -n "$PLATFORM_NS" -o jsonpath='{.status.decision}' 2>/dev/null || true)
                if [ "$rar_decision" != "Approved" ]; then
                    auto_approve_rar "$rr_name" || true
                fi
            fi
        fi

        # Show WFE progress during Executing phase
        if [ "$phase" = "Executing" ]; then
            show_wfe_progress "$target_ns"
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Pipeline timed out after ${timeout}s (last phase: ${prev_phase})"
    return 1
}

# Wait for EA after pipeline completion (if applicable).
_wait_for_ea() {
    local target_ns="$1"
    local timeout=300
    local elapsed=0
    local interval=15

    local ea_phase
    ea_phase=$(get_ea_phase "$target_ns")
    if [ -z "$ea_phase" ]; then
        log_phase "Waiting for EffectivenessAssessment..."
        while [ "$elapsed" -lt 60 ]; do
            ea_phase=$(get_ea_phase "$target_ns")
            if [ -n "$ea_phase" ]; then break; fi
            sleep 5
            elapsed=$((elapsed + 5))
        done
    fi

    if [ -z "$ea_phase" ]; then
        log_info "(no EffectivenessAssessment created)"
        return
    fi

    log_phase "Waiting for EffectivenessAssessment to complete..."
    elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        ea_phase=$(get_ea_phase "$target_ns")
        case "$ea_phase" in
            Completed|Failed)
                show_effectiveness "$target_ns"
                return
                ;;
        esac
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_warn "EA did not complete within ${timeout}s"
    show_effectiveness "$target_ns"
}

# ── Assertion helpers ────────────────────────────────────────────────────────

assert_eq() {
    local actual="$1"
    local expected="$2"
    local label="$3"
    _ASSERT_TOTAL=$((_ASSERT_TOTAL + 1))

    if [ "$actual" = "$expected" ]; then
        _ASSERT_PASS=$((_ASSERT_PASS + 1))
        printf '           %s[PASS]%s %s = %s\n' "$_c_green" "$_c_reset" "$label" "$actual"
    else
        _ASSERT_FAIL=$((_ASSERT_FAIL + 1))
        printf '           %s[FAIL]%s %s = %s (expected: %s)\n' "$_c_red" "$_c_reset" "$label" "$actual" "$expected"
    fi
}

assert_neq() {
    local actual="$1"
    local unexpected="$2"
    local label="$3"
    _ASSERT_TOTAL=$((_ASSERT_TOTAL + 1))

    if [ "$actual" != "$unexpected" ]; then
        _ASSERT_PASS=$((_ASSERT_PASS + 1))
        printf '           %s[PASS]%s %s = %s (not %s)\n' "$_c_green" "$_c_reset" "$label" "$actual" "$unexpected"
    else
        _ASSERT_FAIL=$((_ASSERT_FAIL + 1))
        printf '           %s[FAIL]%s %s = %s (should not be %s)\n' "$_c_red" "$_c_reset" "$label" "$actual" "$unexpected"
    fi
}

assert_gt() {
    local actual="$1"
    local threshold="$2"
    local label="$3"
    _ASSERT_TOTAL=$((_ASSERT_TOTAL + 1))

    if [ "$actual" -gt "$threshold" ] 2>/dev/null; then
        _ASSERT_PASS=$((_ASSERT_PASS + 1))
        printf '           %s[PASS]%s %s = %s (> %s)\n' "$_c_green" "$_c_reset" "$label" "$actual" "$threshold"
    else
        _ASSERT_FAIL=$((_ASSERT_FAIL + 1))
        printf '           %s[FAIL]%s %s = %s (expected > %s)\n' "$_c_red" "$_c_reset" "$label" "$actual" "$threshold"
    fi
}

assert_in() {
    local actual="$1"
    local label="$2"
    shift 2
    _ASSERT_TOTAL=$((_ASSERT_TOTAL + 1))

    for expected in "$@"; do
        if [ "$actual" = "$expected" ]; then
            _ASSERT_PASS=$((_ASSERT_PASS + 1))
            printf '           %s[PASS]%s %s = %s\n' "$_c_green" "$_c_reset" "$label" "$actual"
            return
        fi
    done
    _ASSERT_FAIL=$((_ASSERT_FAIL + 1))
    printf '           %s[FAIL]%s %s = %s (expected one of: %s)\n' "$_c_red" "$_c_reset" "$label" "$actual" "$*"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    _ASSERT_TOTAL=$((_ASSERT_TOTAL + 1))

    if echo "$haystack" | grep -q "$needle" 2>/dev/null; then
        _ASSERT_PASS=$((_ASSERT_PASS + 1))
        printf '           %s[PASS]%s %s contains "%s"\n' "$_c_green" "$_c_reset" "$label" "$needle"
    else
        _ASSERT_FAIL=$((_ASSERT_FAIL + 1))
        printf '           %s[FAIL]%s %s does not contain "%s"\n' "$_c_red" "$_c_reset" "$label" "$needle"
    fi
}

# Print final result summary. Returns 0 on all-pass, 1 on any failure.
print_result() {
    local scenario_name="${1:-scenario}"
    printf '\n'
    printf '           %s%sScenario Assertions%s\n' "$_c_bold" "$_c_cyan" "$_c_reset"
    printf '           %s──────────────────────────────────────────%s\n' "$_c_dim" "$_c_reset"

    if [ "$_ASSERT_FAIL" -eq 0 ]; then
        printf '\n           %s%s============================================%s\n' "$_c_bold" "$_c_green" "$_c_reset"
        printf '           %s%s RESULT: PASS (%d/%d assertions passed)%s\n' "$_c_bold" "$_c_green" "$_ASSERT_PASS" "$_ASSERT_TOTAL" "$_c_reset"
        printf '           %s%s============================================%s\n\n' "$_c_bold" "$_c_green" "$_c_reset"
        return 0
    else
        printf '\n           %s%s============================================%s\n' "$_c_bold" "$_c_red" "$_c_reset"
        printf '           %s%s RESULT: FAIL (%d/%d passed, %d failed)%s\n' "$_c_bold" "$_c_red" "$_ASSERT_PASS" "$_ASSERT_TOTAL" "$_ASSERT_FAIL" "$_c_reset"
        printf '           %s%s============================================%s\n\n' "$_c_bold" "$_c_red" "$_c_reset"
        return 1
    fi
}

# Reset assertion counters (useful when running multiple scenarios).
reset_assertions() {
    _ASSERT_PASS=0
    _ASSERT_FAIL=0
    _ASSERT_TOTAL=0
}
