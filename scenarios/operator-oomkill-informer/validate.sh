#!/usr/bin/env bash
# Validate the GitOps-managed operator OOM closed loop (#446).
#
# Fleet mode validates one successful, human-gated PR remediation while the
# ConfigMap stimulus remains present, then observes a bounded number of
# recurrence cycles so the platform can expose the linked remediation history.
# The workflow Job is deliberately RR-agnostic: this validator must not require
# it to decide recurrence or emit a human handoff.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NAMESPACE="${OPERATOR_GITOPS_NAMESPACE:-demo-controllers}"
APP_NAME="${OPERATOR_GITOPS_APP_NAME:-operator-oomkill-informer}"
APPROVE_MODE="--auto-approve"
FLEET_MODE="${FLEET_MODE:-false}"

# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

for _arg in "$@"; do
    case "${_arg}" in
        --interactive)  APPROVE_MODE="--interactive" ;;
        --auto-approve) APPROVE_MODE="--auto-approve" ;;
        --fleet)        FLEET_MODE=true ;;
    esac
done

# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

PIPELINE_TIMEOUT="${PIPELINE_TIMEOUT:-$([ "${FLEET_MODE:-false}" = true ] && echo 1800 || echo 720)}"
INITIAL_FLOOD_COUNT="${INITIAL_FLOOD_COUNT:-100}"
RECURRENCE_ENABLED="${RECURRENCE_ENABLED:-true}"
RECURRENCE_OBSERVATION_CYCLES="${RECURRENCE_OBSERVATION_CYCLES:-3}"
RECURRENCE_FLOOD_COUNT="${RECURRENCE_FLOOD_COUNT:-auto}"
ALERT_CLEAR_TIMEOUT="${ALERT_CLEAR_TIMEOUT:-600}"
GITEA_REPO="${OPERATOR_GITOPS_REPO:-demo-operator-oomkill-repo}"
GITEA_USER="${GITEA_ADMIN_USER:-kubernaut}"
GITEA_PASS="${GITEA_ADMIN_PASS:-kubernaut123}"
GITEA_REVIEWER="${GITEA_REVIEWER_USER:-sre-reviewer}"
GITEA_PF_PID=""
GITEA_JSON_DIR=""

cleanup_gitea_port_forward() {
    if [ -n "${GITEA_PF_PID}" ]; then
        kill "${GITEA_PF_PID}" 2>/dev/null || true
        GITEA_PF_PID=""
    fi
}

start_gitea_port_forward() {
    cleanup_gitea_port_forward
    kill_stale_gitea_pf 2>/dev/null || true
    kubectl port-forward -n gitea svc/gitea-http \
        "${GITEA_LOCAL_PORT}:3000" &>/dev/null &
    GITEA_PF_PID=$!
    wait_for_port "${GITEA_LOCAL_PORT}" 45
}

gitea_get_json() {
    local path="$1" output="$2"
    curl -sS -u "${GITEA_USER}:${GITEA_PASS}" \
        -o "${output}" -w '%{http_code}' \
        "http://localhost:${GITEA_LOCAL_PORT}/api/v1${path}" || true
}

cleanup_validation_artifacts() {
    cleanup_gitea_port_forward
    if [ -n "${GITEA_JSON_DIR:-}" ]; then
        rm -rf "${GITEA_JSON_DIR}"
    fi
}
trap cleanup_validation_artifacts EXIT

# Workflow Jobs use a short finished-job retention period. Capture their
# evidence at the Verifying transition, before the effectiveness wait can
# allow the Job/Pod to be garbage-collected; the post-EA read remains a
# fallback for installations with longer retention.
JOB_LOG=""
capture_workflow_job_log() {
    local rr_name="${VALIDATION_RR_NAME:-}" wfe_name job_name current_job_log
    [ -n "${rr_name}" ] || return 0
    wfe_name=$(jsonpath_or_empty remediationrequests "${rr_name}" "${PLATFORM_NS}" \
        '{.status.phaseProgress.workflowExecutionRef.name}')
    wfe_name="${wfe_name:-we-${rr_name}}"
    job_name=$(jsonpath_or_empty workflowexecutions "${wfe_name}" "${PLATFORM_NS}" \
        '{.status.executionRef.name}')
    [ -n "${job_name}" ] || return 0
    current_job_log=$(kubectl logs "job/${job_name}" -n "${WE_NAMESPACE:-kubernaut-workflows}" \
        --all-containers=true 2>/dev/null || true)
    if [ -n "${current_job_log}" ]; then
        JOB_LOG="${current_job_log}"
    fi
}

validate_positive_integer() {
    local variable_name="$1" value="$2"
    case "${value}" in
        ''|*[!0-9]*)
            echo "ERROR: ${variable_name} must be a positive integer" >&2
            exit 1
            ;;
    esac
    [ "${value}" -gt 0 ] || {
        echo "ERROR: ${variable_name} must be greater than zero" >&2
        exit 1
    }
}

validate_flood_count() {
    local variable_name="$1" value="$2"
    if [ "${value}" = "auto" ]; then
        return 0
    fi
    validate_positive_integer "${variable_name}" "${value}"
}

validate_positive_integer INITIAL_FLOOD_COUNT "${INITIAL_FLOOD_COUNT}"
validate_positive_integer RECURRENCE_OBSERVATION_CYCLES "${RECURRENCE_OBSERVATION_CYCLES}"
validate_flood_count RECURRENCE_FLOOD_COUNT "${RECURRENCE_FLOOD_COUNT}"

jsonpath_or_empty() {
    local resource="$1" name="$2" namespace="$3" path="$4"
    kubectl get "${resource}" "${name}" -n "${namespace}" -o "jsonpath=${path}" 2>/dev/null || true
}

wait_for_argocd_revision() {
    local expected_revision="$1"
    local timeout="${2:-300}"
    local elapsed=0
    local current_revision sync_status health_status
    while [ "${elapsed}" -lt "${timeout}" ]; do
        sync_status=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NAMESPACE:-argocd}" \
            -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
        health_status=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NAMESPACE:-argocd}" \
            -o jsonpath='{.status.health.status}' 2>/dev/null || true)
        current_revision=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NAMESPACE:-argocd}" \
            -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)
        if [ "${sync_status}" = "Synced" ] && [ "${health_status}" = "Healthy" ] && \
           { [ -z "${expected_revision}" ] || [ "${current_revision}" = "${expected_revision}" ]; }; then
            printf '%s\n' "${current_revision}"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    printf '%s\n' "${current_revision:-}"
    return 1
}

configmap_flood_count() {
    fleet_target_kubectl get configmaps -n "${NAMESPACE}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null | awk '/^app-config-[0-9]+$/ { count++ } END { print count + 0 }'
}

cleanup_stimulus() {
    local name
    echo "==> Removing the retained ConfigMap stimulus after all evidence is captured..."
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        fleet_target_kubectl delete configmap "${name}" -n "${NAMESPACE}" \
            --ignore-not-found 2>/dev/null || true
    done < <(fleet_target_kubectl get configmaps -n "${NAMESPACE}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk '/^app-config-[0-9]+$/')
}

# Preserve the established single-cluster contract: without a hub/spoke pair
# there is no Argo CD Application to review, so live GitOps markers are
# removed by local/run.sh and the generic direct workflow remains selected.
run_local_direct_validation() {
    log_phase "Waiting for the local KubePodCrashLooping alert..."
    wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 480
    show_alert "KubePodCrashLooping" "${NAMESPACE}"

    unset VALIDATION_RR_NAME
    wait_for_rr "${NAMESPACE}" 180
    FIRST_RR=$(get_rr_name "${NAMESPACE}")
    export VALIDATION_RR_NAME="${FIRST_RR}"
    _poll_rc=0
    poll_pipeline "${NAMESPACE}" "${PIPELINE_TIMEOUT}" "${APPROVE_MODE}" || _poll_rc=$?

    RR_PHASE=$(get_rr_phase "${NAMESPACE}")
    RR_OUTCOME=$(get_rr_outcome "${NAMESPACE}")
    AA_NAME="ai-${FIRST_RR}"
    AA_BUNDLE=$(jsonpath_or_empty aianalyses "${AA_NAME}" "${PLATFORM_NS}" '{.status.rcaResult.selectedWorkflow.executionBundle}')
    AA_TARGET_KIND=$(jsonpath_or_empty aianalyses "${AA_NAME}" "${PLATFORM_NS}" '{.status.rcaResult.rootCauseAnalysis.remediationTarget.kind}')
    AA_TARGET_NAME=$(jsonpath_or_empty aianalyses "${AA_NAME}" "${PLATFORM_NS}" '{.status.rcaResult.rootCauseAnalysis.remediationTarget.name}')
    AA_GITOPS_MANAGED=$(jsonpath_or_empty aianalyses "${AA_NAME}" "${PLATFORM_NS}" '{.status.postRCAContext.detectedLabels.gitOpsManaged}')
    AA_GITOPS_TOOL=$(jsonpath_or_empty aianalyses "${AA_NAME}" "${PLATFORM_NS}" '{.status.postRCAContext.detectedLabels.gitOpsTool}')
    WFE_PHASE=$(get_wfe_phase "${NAMESPACE}")
    RAR_DECISION=$(jsonpath_or_empty remediationapprovalrequest "rar-${FIRST_RR}" "${PLATFORM_NS}" '{.status.decision}')

    log_phase "Running local direct-workflow assertions..."
    assert_eq "${_poll_rc}" "0" "local pipeline returned successfully"
    assert_eq "${RR_PHASE}" "Completed" "local RR phase"
    assert_eq "${RR_OUTCOME}" "Remediated" "local RR outcome"
    assert_eq "${WFE_PHASE}" "Completed" "local WFE phase"
    assert_contains "${AA_BUNDLE}" "increase-memory-limits-job" "generic IncreaseMemoryLimits bundle selected"
    assert_eq "${AA_TARGET_KIND}" "Deployment" "local RCA target kind"
    assert_eq "${AA_TARGET_NAME}" "demo-controllers-controller" "local RCA target name"
    assert_eq "${AA_GITOPS_MANAGED}" "false" "local run is not GitOps-managed"
    assert_eq "${AA_GITOPS_TOOL}" "" "local GitOps tool label is empty"
    assert_eq "${RAR_DECISION}" "Approved" "local RAR decision"

    APPLIED_LIMIT=$(kubectl get deployment/demo-controllers-controller -n "${NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)
    EA_PHASE=$(get_ea_phase "${NAMESPACE}")
    assert_neq "${APPLIED_LIMIT}" "128Mi" "local Deployment memory limit changed"
    assert_eq "${EA_PHASE}" "Completed" "local effectiveness assessment phase"

    cleanup_stimulus
    unset VALIDATION_RR_NAME
    print_result "operator-oomkill-informer-local"
}

if [ "${FLEET_MODE:-false}" != true ]; then
    run_local_direct_validation
    exit $?
fi

# Alertmanager keeps a firing alert until the spoke signal has decayed. A new
# RR must be observed after that decay; otherwise Gateway deduplication can
# make a recurrence look like a second pass through the first RR.
fleet_alert_present() {
    local alert_name="$1" namespace="$2" cluster="$3" pod alerts
    pod=$(command kubectl --kubeconfig="${HUB_KUBECONFIG}" get pods -n "${FLEET_MONITORING_NS:-monitoring}" \
        -l app=alertmanager --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "${pod}" ] || return 2
    alerts=$(command kubectl --kubeconfig="${HUB_KUBECONFIG}" exec -n "${FLEET_MONITORING_NS:-monitoring}" \
        "${pod}" -- wget -qO- http://localhost:9093/api/v2/alerts 2>/dev/null || true)
    [ -n "${alerts}" ] || return 2
    printf '%s' "${alerts}" | python3 -c '
import json, sys
alert_name, namespace, cluster = sys.argv[1:]
for alert in json.load(sys.stdin):
    labels = alert.get("labels", {})
    if labels.get("alertname") == alert_name and labels.get("namespace") == namespace and (not cluster or labels.get("cluster") == cluster):
        raise SystemExit(0)
raise SystemExit(1)
' "${alert_name}" "${namespace}" "${cluster}"
}

wait_for_fleet_alert_clear() {
    if [ "${FLEET_MODE:-false}" != true ]; then
        sleep "${ALERT_CLEAR_TIMEOUT}"
        return 0
    fi
    local cluster="${SPOKE_CLUSTER_LABEL:-${FLEET_CLUSTER_ID:-remote-cluster}}"
    local elapsed=0
    while [ "${elapsed}" -lt "${ALERT_CLEAR_TIMEOUT}" ]; do
        if fleet_alert_present "KubePodCrashLooping" "${NAMESPACE}" "${cluster}"; then
            :
        else
            local probe_rc=$?
            if [ "${probe_rc}" -eq 1 ]; then
                return 0
            fi
            echo "WARNING: unable to query hub Alertmanager while waiting for alert decay; retrying." >&2
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo "WARNING: alert did not clear within ${ALERT_CLEAR_TIMEOUT}s; continuing so Gateway can prove whether it deduplicates the recurrence." >&2
    return 1
}

wait_for_new_rr() {
    local previous_rr="$1" previous_created_at="$2" timeout="${3:-300}"
    local elapsed=0 candidate
    while [ "${elapsed}" -lt "${timeout}" ]; do
        candidate=$(kubectl get remediationrequests -n "${PLATFORM_NS}" -o json 2>/dev/null \
            | jq -r --arg ns "${NAMESPACE}" --arg old "${previous_rr}" --arg created "${previous_created_at}" '
                [.items[] | select(.spec.signalLabels.namespace == $ns and .metadata.name != $old and
                    (.metadata.creationTimestamp > $created))]
                | sort_by(.metadata.creationTimestamp) | if length == 0 then "" else .[-1].metadata.name end' \
            2>/dev/null || true)
        if [ -n "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 1
}

history_chain_metrics_from_audit() {
    local audit_file="$1"
    python3 - "${audit_file}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
try:
    events = json.loads(text)
except json.JSONDecodeError:
    line = next((line for line in text.splitlines() if line.lstrip().startswith("[")), "[]")
    events = json.loads(line)

maximum = 0
maximum_links = 0
for event in events or []:
    data = event.get("event_data") or {}
    if data.get("tool_name") != "get_namespaced_resource_context":
        continue
    result = data.get("tool_result")
    if isinstance(result, str):
        try:
            result = json.loads(result)
        except json.JSONDecodeError:
            continue
    history = result.get("remediation_history") if isinstance(result, dict) else None
    if not isinstance(history, dict):
        continue
    tier1 = history.get("tier1") or []
    tier2 = history.get("tier2") or []
    maximum = max(maximum, len(tier1) + len(tier2))
    ordered = sorted(tier1, key=lambda entry: entry.get("completed_at", ""))
    links = sum(
        1
        for previous, current in zip(ordered, ordered[1:])
        if previous.get("post_remediation_spec_hash")
        and previous.get("post_remediation_spec_hash") == current.get("pre_remediation_spec_hash")
    )
    maximum_links = max(maximum_links, links)

print(f"{maximum}\t{maximum_links}")
PY
}

log_phase "Waiting for the first KubePodCrashLooping alert..."
wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 480
show_alert "KubePodCrashLooping" "${NAMESPACE}"

unset VALIDATION_RR_NAME
wait_for_rr "${NAMESPACE}" 180
FIRST_RR=$(get_rr_name "${NAMESPACE}")
export VALIDATION_RR_NAME="${FIRST_RR}"
JOB_LOG=""
export ON_VERIFYING_HOOK=capture_workflow_job_log
_poll_rc=0
poll_pipeline "${NAMESPACE}" "${PIPELINE_TIMEOUT}" "${APPROVE_MODE}" || _poll_rc=$?

log_phase "Running first-cycle assertions..."
RR_PHASE=$(get_rr_phase "${NAMESPACE}")
RR_OUTCOME=$(get_rr_outcome "${NAMESPACE}")
SP_PHASE=$(get_sp_phase "${NAMESPACE}")
AA_NAME="ai-${FIRST_RR}"
AA_PHASE=$(jsonpath_or_empty aianalyses "${AA_NAME}" "${PLATFORM_NS}" '{.status.phase}')
AA_BUNDLE=$(jsonpath_or_empty aianalyses "${AA_NAME}" "${PLATFORM_NS}" '{.status.rcaResult.selectedWorkflow.executionBundle}')
AA_TARGET_KIND=$(jsonpath_or_empty aianalyses "${AA_NAME}" "${PLATFORM_NS}" '{.status.rcaResult.rootCauseAnalysis.remediationTarget.kind}')
AA_TARGET_NAME=$(jsonpath_or_empty aianalyses "${AA_NAME}" "${PLATFORM_NS}" '{.status.rcaResult.rootCauseAnalysis.remediationTarget.name}')
AA_TARGET_NAMESPACE=$(jsonpath_or_empty aianalyses "${AA_NAME}" "${PLATFORM_NS}" '{.status.rcaResult.rootCauseAnalysis.remediationTarget.namespace}')
AA_GITOPS_MANAGED=$(jsonpath_or_empty aianalyses "${AA_NAME}" "${PLATFORM_NS}" '{.status.postRCAContext.detectedLabels.gitOpsManaged}')
AA_GITOPS_TOOL=$(jsonpath_or_empty aianalyses "${AA_NAME}" "${PLATFORM_NS}" '{.status.postRCAContext.detectedLabels.gitOpsTool}')
RAR_DECISION=$(jsonpath_or_empty remediationapprovalrequest "rar-${FIRST_RR}" "${PLATFORM_NS}" '{.status.decision}')
RAR_DECIDED_BY=$(jsonpath_or_empty remediationapprovalrequest "rar-${FIRST_RR}" "${PLATFORM_NS}" '{.status.decidedBy}')

assert_eq "${_poll_rc}" "0" "first pipeline returned successfully"
assert_eq "${RR_PHASE}" "Completed" "first RR phase"
assert_eq "${RR_OUTCOME}" "Remediated" "first RR outcome"
assert_eq "${SP_PHASE}" "Completed" "first SP phase"
assert_eq "${AA_PHASE}" "Completed" "first AA phase"
assert_contains "${AA_BUNDLE}" "increase-memory-limits-gitops-job" "GitOps IncreaseMemoryLimits bundle selected"
assert_eq "${AA_TARGET_KIND}" "Deployment" "RCA target kind"
assert_eq "${AA_TARGET_NAME}" "demo-controllers-controller" "RCA target name"
assert_eq "${AA_TARGET_NAMESPACE}" "${NAMESPACE}" "RCA target namespace"
assert_eq "${AA_GITOPS_MANAGED}" "true" "GitOps detected label"
assert_eq "${AA_GITOPS_TOOL}" "argocd" "GitOps tool detected label"
assert_eq "${RAR_DECISION}" "Approved" "first RAR decision"
assert_neq "${RAR_DECIDED_BY}" "" "first RAR decision actor"

WFE_NAME=$(jsonpath_or_empty remediationrequests "${FIRST_RR}" "${PLATFORM_NS}" \
    '{.status.phaseProgress.workflowExecutionRef.name}')
WFE_NAME="${WFE_NAME:-we-${FIRST_RR}}"
WFE_CLUSTER=$(jsonpath_or_empty workflowexecutions "${WFE_NAME}" "${PLATFORM_NS}" '{.spec.clusterID}')
JOB_NAME=$(jsonpath_or_empty workflowexecutions "${WFE_NAME}" "${PLATFORM_NS}" '{.status.executionRef.name}')
if [ -n "${JOB_NAME}" ]; then
    _current_job_log=$(kubectl logs "job/${JOB_NAME}" -n "${WE_NAMESPACE:-kubernaut-workflows}" \
        --all-containers=true 2>/dev/null || true)
    if [ -n "${_current_job_log}" ]; then
        JOB_LOG="${_current_job_log}"
    fi
fi
if [ "${FLEET_MODE:-false}" = true ]; then
assert_eq "${WFE_CLUSTER}" "hub" "workflow execution cluster"
fi
assert_contains "${JOB_LOG}" "FORWARD_CHANGE_PR_URL" "forward-change PR is observable"
assert_contains "${JOB_LOG}" "PR_STATE=merged" "Job waited for the human PR merge"
FORBIDDEN_WORKFLOW_ACTIONS=$(printf '%s' "${JOB_LOG}" | grep -Ei '/pulls/.*/merge|git push .* main|kubectl .* (patch|apply|edit)' || true)
assert_eq "${FORBIDDEN_WORKFLOW_ACTIONS}" "" "workflow log contains no auto-merge/direct-main-push/live-patch action"

MERGED_SHA=$(printf '%s\n' "${JOB_LOG}" | sed -n 's/^PR_MERGED_COMMIT_SHA=//p' | tail -1)
PR_NUMBER=$(printf '%s\n' "${JOB_LOG}" | sed -n 's/^FORWARD_CHANGE_PR_NUMBER=//p' | tail -1)
PR_URL=$(printf '%s\n' "${JOB_LOG}" | sed -n 's/^FORWARD_CHANGE_PR_URL=//p' | tail -1)
PR_MERGED_BY=$(printf '%s\n' "${JOB_LOG}" | sed -n 's/^PR_MERGED_BY=//p' | tail -1)
assert_neq "${MERGED_SHA}" "" "merged PR commit SHA recorded"
assert_neq "${PR_NUMBER}" "" "PR number recorded"
assert_neq "${PR_URL}" "" "PR URL recorded"
assert_neq "${PR_MERGED_BY}" "" "human merge actor recorded"
assert_eq "${PR_MERGED_BY}" "${GITEA_REVIEWER}" "protected PR was manually merged by the reviewer"

if [ "${FLEET_MODE:-false}" = true ] && [ -n "${PR_NUMBER}" ]; then
    log_phase "Verifying Gitea branch protection and independent human review..."
    start_gitea_port_forward
    GITEA_JSON_DIR=$(mktemp -d)
    PROTECTION_FILE="${GITEA_JSON_DIR}/protection.json"
    REVIEWS_FILE="${GITEA_JSON_DIR}/reviews.json"
    PROTECTION_CODE=$(gitea_get_json "/repos/${GITEA_USER}/${GITEA_REPO}/branch_protections/main" "${PROTECTION_FILE}")
    REVIEWS_CODE=$(gitea_get_json "/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${PR_NUMBER}/reviews" "${REVIEWS_FILE}")
    assert_eq "${PROTECTION_CODE}" "200" "Gitea main branch protection API response"
    assert_eq "${REVIEWS_CODE}" "200" "Gitea PR reviews API response"
    # jq's `//` treats boolean false as absent; preserve the explicit false
    # returned by Gitea for protected-main direct pushes.
    PROTECTED_PUSH=$(jq -r 'if has("enable_push") then .enable_push else empty end' \
        "${PROTECTION_FILE}" 2>/dev/null || true)
    REQUIRED_APPROVALS=$(jq -r '.required_approvals // 0' "${PROTECTION_FILE}" 2>/dev/null || true)
    ADMIN_OVERRIDE=$(jq -r '.block_admin_merge_override // false' "${PROTECTION_FILE}" 2>/dev/null || true)
    HUMAN_APPROVALS=$(jq -r --arg reviewer "${GITEA_REVIEWER}" \
        '[.[] | select((.state | ascii_upcase) == "APPROVED" and .user.login == $reviewer)] | length' \
        "${REVIEWS_FILE}" 2>/dev/null || echo "0")
    assert_eq "${PROTECTED_PUSH}" "false" "Gitea protected main rejects direct pushes"
    assert_gt "${REQUIRED_APPROVALS}" "0" "Gitea requires a PR approval"
    assert_eq "${ADMIN_OVERRIDE}" "true" "Gitea blocks administrator merge override"
    assert_gt "${HUMAN_APPROVALS}" "0" "independent human reviewer approved the PR"
    rm -rf "${GITEA_JSON_DIR}"
    cleanup_gitea_port_forward
fi

APP_REVISION=$(wait_for_argocd_revision "${MERGED_SHA}" 360 2>/dev/null || true)
assert_neq "${APP_REVISION}" "" "Argo CD applied revision"
if [ -n "${APP_REVISION}" ] && [ -n "${MERGED_SHA}" ]; then
    assert_eq "${APP_REVISION}" "${MERGED_SHA}" "Argo CD applied merged revision"
fi

fleet_target_kubectl wait --for=condition=Available deployment/demo-controllers-controller \
    -n "${NAMESPACE}" --timeout=180s >/dev/null 2>&1 || true
APPLIED_LIMIT=$(fleet_target_kubectl get deployment/demo-controllers-controller -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)
APPLIED_REQUEST=$(fleet_target_kubectl get deployment/demo-controllers-controller -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null || true)
READY_REPLICAS=$(fleet_target_kubectl get deployment/demo-controllers-controller -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
TOP_OUTPUT=$(fleet_target_kubectl top pod -n "${NAMESPACE}" \
    -l app=demo-controllers-controller --no-headers 2>/dev/null || true)
RETAINED_COUNT=$(configmap_flood_count)
EA_PHASE=$(get_ea_phase "${NAMESPACE}")
EA_HEALTH=$(jsonpath_or_empty effectivenessassessments "ea-${FIRST_RR}" "${PLATFORM_NS}" '{.status.components.healthScore}')
EA_ALERT=$(jsonpath_or_empty effectivenessassessments "ea-${FIRST_RR}" "${PLATFORM_NS}" '{.status.components.alertScore}')
EA_HEALTH_ASSESSED=$(jsonpath_or_empty effectivenessassessments "ea-${FIRST_RR}" "${PLATFORM_NS}" '{.status.components.healthAssessed}')
EA_ALERT_ASSESSED=$(jsonpath_or_empty effectivenessassessments "ea-${FIRST_RR}" "${PLATFORM_NS}" '{.status.components.alertAssessed}')
EA_METRICS_ASSESSED=$(jsonpath_or_empty effectivenessassessments "ea-${FIRST_RR}" "${PLATFORM_NS}" '{.status.components.metricsAssessed}')
EA_REASON=$(jsonpath_or_empty effectivenessassessments "ea-${FIRST_RR}" "${PLATFORM_NS}" '{.status.assessmentReason}')

assert_eq "${APPLIED_LIMIT}" "256Mi" "spoke Deployment memory limit increased by exactly 128Mi"
assert_eq "${APPLIED_REQUEST}" "32Mi" "spoke Deployment memory request preserved"
assert_eq "${READY_REPLICAS}" "1" "spoke operator ready replicas"
assert_neq "${TOP_OUTPUT}" "" "spoke memory evidence available"
assert_gt "${RETAINED_COUNT}" $((INITIAL_FLOOD_COUNT - 1)) "ConfigMap stimulus retained during EA"
assert_eq "${EA_PHASE}" "Completed" "first effectiveness assessment phase"
assert_eq "${EA_HEALTH_ASSESSED}" "true" "effectiveness health component assessed"
assert_eq "${EA_ALERT_ASSESSED}" "true" "effectiveness alert component assessed"
assert_eq "${EA_METRICS_ASSESSED}" "true" "effectiveness metrics component assessed"
assert_neq "${EA_HEALTH}" "" "first effectiveness health score recorded"
assert_neq "${EA_HEALTH}" "NaN" "first effectiveness health score is numeric"
assert_neq "${EA_ALERT}" "" "first effectiveness alert score recorded"
assert_neq "${EA_REASON}" "" "effectiveness assessment reason recorded"

if [ "${FLEET_MODE:-false}" = true ] && [ "${RECURRENCE_ENABLED}" = true ]; then
    log_phase "Beginning controlled recurrence; the initial ConfigMaps remain present."
    next_start=$((INITIAL_FLOOD_COUNT + 1))
    for cycle in $(seq 2 "${RECURRENCE_OBSERVATION_CYCLES}"); do
        echo "==> Recurrence cycle ${cycle}: waiting for the previous alert to clear..."
        wait_for_fleet_alert_clear || true
        PREVIOUS_RR_CREATED_AT=$(jsonpath_or_empty remediationrequests "${VALIDATION_RR_NAME}" "${PLATFORM_NS}" '{.metadata.creationTimestamp}')
        echo "==> Recurrence cycle ${cycle}: adding ${RECURRENCE_FLOOD_COUNT} more ConfigMaps."
        NAMESPACE="${NAMESPACE}" CONFIGMAP_COUNT="${RECURRENCE_FLOOD_COUNT}" \
            TARGET_DEPLOYMENT=demo-controllers-controller \
            CONFIGMAP_START="${next_start}" CONFIGMAP_PREFIX=app-config KUBECONFIG="${SPOKE_KUBECONFIG}" \
            bash "${SCRIPT_DIR}/inject-configmap-flood.sh"
        next_start=$(( $(configmap_flood_count) + 1 ))
        fleet_wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 480
        previous_rr="${VALIDATION_RR_NAME}"
        SECOND_RR=$(wait_for_new_rr "${previous_rr}" "${PREVIOUS_RR_CREATED_AT}" 600 || true)
        if [ -z "${SECOND_RR}" ]; then
            echo "ERROR: recurrence alert fired but no new RR was observed; refusing to call this history-informed." >&2
            assert_neq "${SECOND_RR}" "" "new RR created for recurrence"
            break
        fi
        export VALIDATION_RR_NAME="${SECOND_RR}"
        JOB_LOG=""
        export ON_VERIFYING_HOOK=capture_workflow_job_log
        cycle_rc=0
        poll_pipeline "${NAMESPACE}" "${PIPELINE_TIMEOUT}" "${APPROVE_MODE}" || cycle_rc=$?
        cycle_phase=$(get_rr_phase "${NAMESPACE}")
        cycle_outcome=$(get_rr_outcome "${NAMESPACE}")
        cycle_aa="ai-${SECOND_RR}"
        cycle_reason=$(jsonpath_or_empty aianalyses "${cycle_aa}" "${PLATFORM_NS}" '{.status.review.humanReviewReason}')
        cycle_subreason=$(jsonpath_or_empty aianalyses "${cycle_aa}" "${PLATFORM_NS}" '{.status.subReason}')
        cycle_requires_review=$(jsonpath_or_empty remediationrequests "${SECOND_RR}" "${PLATFORM_NS}" '{.status.completionStatus.requiresManualReview}')
        cycle_block_reason=$(jsonpath_or_empty remediationrequests "${SECOND_RR}" "${PLATFORM_NS}" '{.status.routingStatus.blockReason}')
        retained_now=$(configmap_flood_count)
        echo "  Recurrence RR=${SECOND_RR} phase=${cycle_phase} outcome=${cycle_outcome} reason=${cycle_reason:-${cycle_subreason:-${cycle_block_reason:-none}}} retainedConfigMaps=${retained_now}"
        assert_gt "${retained_now}" "$((INITIAL_FLOOD_COUNT - 1))" "stimulus retained through recurrence cycle ${cycle}"

        # The workflow must not decide recurrence. A stale image containing the
        # old scenario guard is a contract failure, even if RO later classifies
        # the RR as failed or requiring review.
        JOB_LOG=""
        capture_workflow_job_log
        workflow_handoff_marker=$(printf '%s\n' "${JOB_LOG}" | grep -F 'HUMAN_HANDOFF_REQUIRED=' || true)
        assert_eq "${workflow_handoff_marker}" "" "workflow Job remains RR-agnostic at recurrence cycle ${cycle}"

        AUDIT_TRACE_FILE="$(mktemp -t operator-oomkill-audit.XXXXXX)"
        if bash "${REPO_ROOT}/scripts/extract-audit-trace.sh" --fleet "${SECOND_RR}" --json --investigation >"${AUDIT_TRACE_FILE}" 2>&1; then
            history_evidence=$(grep -Eio 'remediation_history|regression_detected|previous remediation|prior remediation|ineffective' "${AUDIT_TRACE_FILE}" | head -1 || true)
            assert_neq "${history_evidence}" "" "recurrence audit contains remediation history evidence"
            history_chain_metrics=$(history_chain_metrics_from_audit "${AUDIT_TRACE_FILE}")
            IFS=$'\t' read -r history_entry_count history_link_count <<<"${history_chain_metrics}"
            # The expected count is derived from the number of preceding
            # observed remediations, not a policy retry threshold. This is the
            # contract that the current target's linked hash chain is complete.
            prior_observed=$((cycle - 1))
            assert_gt "${history_entry_count}" $((prior_observed - 1)) \
                "linked remediation history includes prior entries at recurrence cycle ${cycle}"
            if [ "${prior_observed}" -gt 1 ]; then
                assert_gt "${history_link_count}" $((prior_observed - 2)) \
                    "remediation history preserves pre/post hash links at recurrence cycle ${cycle}"
            fi
            echo "  Audit trace captured at ${AUDIT_TRACE_FILE}; linked history entries=${history_entry_count}, hash links=${history_link_count}"
        else
            echo "WARNING: could not extract the DataStorage audit trace; see ${AUDIT_TRACE_FILE}" >&2
            assert_neq "" "" "DataStorage audit trace extraction"
        fi

        case "${cycle_phase}:${cycle_outcome}:${cycle_requires_review}:${cycle_reason}:${cycle_subreason}:${cycle_block_reason}" in
            *ManualReviewRequired*|*OperatorEscalation*|*operator_escalation*|*Ineffective*|*ConsecutiveFailures*|*true*)
                echo "==> Platform policy reached a human-handoff state at recurrence cycle ${cycle}."
                break
                ;;
        esac
        if [ "${cycle_rc}" -ne 0 ]; then
            echo "WARNING: recurrence cycle ${cycle} returned ${cycle_rc}; stopping the bounded observation window." >&2
            break
        fi
    done
fi

# Only after first-cycle EA and any observed recurrence evidence have been
# captured is it safe to remove the stimulus.
cleanup_stimulus
unset VALIDATION_RR_NAME

print_result "operator-oomkill-informer"
