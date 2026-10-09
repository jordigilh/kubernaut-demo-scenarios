#!/usr/bin/env bash
# Validate the GitOps-managed operator OOM closed loop (#446).
#
# Fleet mode validates human-gated PR remediations while the fixed ConfigMap
# stimulus remains present. The flood is large enough to survive three +128Mi
# increments. The validator waits for the still-firing alert to create follow-up
# RRs, accepts platform escalation on any recurrence, and otherwise continues
# through additional ineffective reviewed remediations. It never clears or
# reinjects the stimulus between cycles.
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
if [ "${FLEET_MODE:-false}" = true ]; then
    INITIAL_FLOOD_COUNT="${INITIAL_FLOOD_COUNT:-600}"
else
    INITIAL_FLOOD_COUNT="${INITIAL_FLOOD_COUNT:-100}"
fi
SECOND_RR_TIMEOUT="${SECOND_RR_TIMEOUT:-600}"
MAX_RR_CYCLES="${MAX_RR_CYCLES:-4}"
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

gitea_pull_count() {
    local output="$1" code
    code=$(gitea_get_json \
        "/repos/${GITEA_USER}/${GITEA_REPO}/pulls?state=all&limit=50" "${output}")
    GITEA_PULL_COUNT_CODE="${code}"
    if [ "${code}" = "200" ]; then
        jq 'length' "${output}"
    else
        printf '%s\n' "-1"
    fi
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

validate_positive_integer INITIAL_FLOOD_COUNT "${INITIAL_FLOOD_COUNT}"
validate_positive_integer SECOND_RR_TIMEOUT "${SECOND_RR_TIMEOUT}"
validate_positive_integer MAX_RR_CYCLES "${MAX_RR_CYCLES}"
[ "${MAX_RR_CYCLES}" -ge 2 ] || {
    echo "ERROR: MAX_RR_CYCLES must be at least two" >&2
    exit 1
}

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

fleet_alert_present() {
    local alert_name="$1" namespace="$2" cluster="$3" pod alerts active_pods
    pod=$(command kubectl --kubeconfig="${HUB_KUBECONFIG}" get pods -n "${FLEET_MONITORING_NS:-monitoring}" \
        -l app=alertmanager --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -n "${pod}" ] || return 2
    # Prometheus' restart-rate rule can retain an alert for a deleted pod until
    # its range window expires. Effectiveness Monitor filters those stale signal
    # pod alerts against the current target pods; mirror that behavior here so
    # recurrence does not wait on an old pod that is no longer failing.
    active_pods=$(command kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get pods \
        -n "${namespace}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null || true)
    [ -n "${active_pods}" ] || return 2
    alerts=$(command kubectl --kubeconfig="${HUB_KUBECONFIG}" exec -n "${FLEET_MONITORING_NS:-monitoring}" \
        "${pod}" -- wget -qO- http://localhost:9093/api/v2/alerts 2>/dev/null || true)
    [ -n "${alerts}" ] || return 2
    printf '%s' "${alerts}" | python3 -c '
import json, sys
alert_name, namespace, cluster, active_pods = sys.argv[1:]
active_pods = set(active_pods.splitlines())
for alert in json.load(sys.stdin):
    labels = alert.get("labels", {})
    # A stale alert for a deleted signal pod is not a live recurrence.
    if labels.get("pod") and labels["pod"] not in active_pods:
        continue
    if labels.get("alertname") == alert_name and labels.get("namespace") == namespace and (not cluster or labels.get("cluster") == cluster):
        raise SystemExit(0)
raise SystemExit(1)
' "${alert_name}" "${namespace}" "${cluster}" "${active_pods}"
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

workflow_execution_exists_for_rr() {
    local rr_name="$1"
    kubectl get workflowexecution "we-${rr_name}" -n "${PLATFORM_NS}" &>/dev/null
}

approval_request_exists_for_rr() {
    local rr_name="$1"
    kubectl get remediationapprovalrequest "rar-${rr_name}" -n "${PLATFORM_NS}" &>/dev/null
}

is_zero_score() {
    case "${1:-}" in
        0|0.0|0.00|0.000) return 0 ;;
        *) return 1 ;;
    esac
}

platform_escalation_evidence() {
    local text="$*"
    printf '%s' "${text}" | grep -Eiq \
        'ineffective|consecutive.?fail|repeated|operator.?escalat|manual.?review|remediation.?history'
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
assert_eq "${RR_OUTCOME}" "Inconclusive" "first RR outcome (ineffective remediation)"
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
FIRST_PR_COUNT=0
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
    PULLS_FILE="${GITEA_JSON_DIR}/pulls.json"
    PROTECTION_CODE=$(gitea_get_json "/repos/${GITEA_USER}/${GITEA_REPO}/branch_protections/main" "${PROTECTION_FILE}")
    REVIEWS_CODE=$(gitea_get_json "/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${PR_NUMBER}/reviews" "${REVIEWS_FILE}")
    gitea_pull_count "${PULLS_FILE}" >/dev/null
    FIRST_PR_COUNT=$(jq 'length' "${PULLS_FILE}" 2>/dev/null || echo "-1")
    assert_eq "${PROTECTION_CODE}" "200" "Gitea main branch protection API response"
    assert_eq "${REVIEWS_CODE}" "200" "Gitea PR reviews API response"
    assert_eq "${GITEA_PULL_COUNT_CODE}" "200" "Gitea pull-request listing API response"
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
    assert_gt "${FIRST_PR_COUNT}" "0" "first remediation created a Gitea pull request"
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
POD_RESTARTS=$(fleet_target_kubectl get pods -n "${NAMESPACE}" \
    -l app=demo-controllers-controller \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || true)
RETAINED_COUNT=$(configmap_flood_count)
EA_PHASE=$(get_ea_phase "${NAMESPACE}")
EA_HEALTH=$(jsonpath_or_empty effectivenessassessments "ea-${FIRST_RR}" "${PLATFORM_NS}" '{.status.components.healthScore}')
EA_ALERT=$(jsonpath_or_empty effectivenessassessments "ea-${FIRST_RR}" "${PLATFORM_NS}" '{.status.components.alertScore}')
EA_HEALTH_ASSESSED=$(jsonpath_or_empty effectivenessassessments "ea-${FIRST_RR}" "${PLATFORM_NS}" '{.status.components.healthAssessed}')
EA_ALERT_ASSESSED=$(jsonpath_or_empty effectivenessassessments "ea-${FIRST_RR}" "${PLATFORM_NS}" '{.status.components.alertAssessed}')
EA_METRICS_ASSESSED=$(jsonpath_or_empty effectivenessassessments "ea-${FIRST_RR}" "${PLATFORM_NS}" '{.status.components.metricsAssessed}')
EA_REASON=$(jsonpath_or_empty effectivenessassessments "ea-${FIRST_RR}" "${PLATFORM_NS}" '{.status.assessmentReason}')
FIRST_ALERT_ACTIVE=false
if [ "${FLEET_MODE:-false}" = true ]; then
    _first_alert_cluster="${SPOKE_CLUSTER_LABEL:-${FLEET_CLUSTER_ID:-remote-cluster}}"
    if fleet_alert_present "KubePodCrashLooping" "${NAMESPACE}" "${_first_alert_cluster}"; then
        FIRST_ALERT_ACTIVE=true
    fi
fi

assert_eq "${APPLIED_LIMIT}" "256Mi" "spoke Deployment memory limit increased by exactly 128Mi"
assert_eq "${APPLIED_REQUEST}" "32Mi" "spoke Deployment memory request preserved"
assert_eq "${READY_REPLICAS}" "1" "spoke operator ready replicas"
if [ -n "${TOP_OUTPUT}" ]; then
    assert_neq "${TOP_OUTPUT}" "" "spoke memory evidence available"
else
    assert_gt "${POD_RESTARTS:-0}" "0" "spoke operator restart evidence"
fi
assert_gt "${RETAINED_COUNT}" $((INITIAL_FLOOD_COUNT - 1)) "ConfigMap stimulus retained during EA"
assert_eq "${EA_PHASE}" "Completed" "first effectiveness assessment phase"
assert_eq "${EA_HEALTH_ASSESSED}" "true" "effectiveness health component assessed"
assert_eq "${EA_ALERT_ASSESSED}" "true" "effectiveness alert component assessed"
assert_eq "${EA_METRICS_ASSESSED}" "true" "effectiveness metrics component assessed"
assert_neq "${EA_HEALTH}" "" "first effectiveness health score recorded"
assert_neq "${EA_HEALTH}" "NaN" "first effectiveness health score is numeric"
assert_neq "${EA_ALERT}" "" "first effectiveness alert score recorded"
assert_neq "${EA_REASON}" "" "effectiveness assessment reason recorded"

if [ "${FLEET_MODE:-false}" = true ]; then
    assert_eq "${FIRST_ALERT_ACTIVE}" "true" "first EA completed while KubePodCrashLooping remained active"
    if is_zero_score "${EA_ALERT}"; then
        FIRST_EA_FAILURE_EVIDENCE="alertScore=${EA_ALERT}"
    elif is_zero_score "${EA_HEALTH}"; then
        FIRST_EA_FAILURE_EVIDENCE="healthScore=${EA_HEALTH}"
    else
        FIRST_EA_FAILURE_EVIDENCE=""
    fi
    assert_neq "${FIRST_EA_FAILURE_EVIDENCE}" "" \
        "first EA has alert/health failure evidence (not metrics-only)"

    # AlertManager repeats the still-firing alert while Gateway's run-scoped
    # cooldown is 0s. A recurrence can either be escalated immediately by
    # platform history/routing or receive another reviewed +128Mi change. The
    # fixed flood remains untouched in both cases.
    LAST_RR="${FIRST_RR}"
    LAST_RR_CREATED_AT=$(jsonpath_or_empty remediationrequests "${LAST_RR}" "${PLATFORM_NS}" '{.metadata.creationTimestamp}')
    LAST_LIMIT="${APPLIED_LIMIT}"
    EXPECTED_PR_COUNT="${FIRST_PR_COUNT}"
    OBSERVED_REMEDIATIONS=1
    ESCALATION_FOUND=false

    for cycle in $(seq 2 "${MAX_RR_CYCLES}"); do
        log_phase "Waiting for continuing alert to create RR cycle ${cycle}; no stimulus reset or reinjection will occur."
        NEXT_RR=$(wait_for_new_rr "${LAST_RR}" "${LAST_RR_CREATED_AT}" "${SECOND_RR_TIMEOUT}" || true)
        assert_neq "${NEXT_RR}" "" "RR cycle ${cycle} created from the continuing alert"
        if [ -z "${NEXT_RR}" ]; then
            break
        fi

        export VALIDATION_RR_NAME="${NEXT_RR}"
        JOB_LOG=""
        export ON_VERIFYING_HOOK=capture_workflow_job_log
        CYCLE_POLL_RC=0
        poll_pipeline "${NAMESPACE}" "${PIPELINE_TIMEOUT}" "${APPROVE_MODE}" || CYCLE_POLL_RC=$?

        CYCLE_PHASE=$(get_rr_phase "${NAMESPACE}")
        CYCLE_OUTCOME=$(get_rr_outcome "${NAMESPACE}")
        CYCLE_AA="ai-${NEXT_RR}"
        CYCLE_AA_PHASE=$(jsonpath_or_empty aianalyses "${CYCLE_AA}" "${PLATFORM_NS}" '{.status.phase}')
        CYCLE_AA_WORKFLOW=$(jsonpath_or_empty aianalyses "${CYCLE_AA}" "${PLATFORM_NS}" '{.status.rcaResult.selectedWorkflow.workflowId}')
        CYCLE_AA_BUNDLE=$(jsonpath_or_empty aianalyses "${CYCLE_AA}" "${PLATFORM_NS}" '{.status.rcaResult.selectedWorkflow.executionBundle}')
        CYCLE_AA_REASON=$(jsonpath_or_empty aianalyses "${CYCLE_AA}" "${PLATFORM_NS}" '{.status.review.humanReviewReason}')
        CYCLE_AA_SUBREASON=$(jsonpath_or_empty aianalyses "${CYCLE_AA}" "${PLATFORM_NS}" '{.status.subReason}')
        CYCLE_REQUIRES_REVIEW=$(jsonpath_or_empty remediationrequests "${NEXT_RR}" "${PLATFORM_NS}" '{.status.completionStatus.requiresManualReview}')
        CYCLE_BLOCK_REASON=$(jsonpath_or_empty remediationrequests "${NEXT_RR}" "${PLATFORM_NS}" '{.status.routingStatus.blockReason}')
        CYCLE_ROUTING_REASON=$(jsonpath_or_empty remediationrequests "${NEXT_RR}" "${PLATFORM_NS}" '{.status.routingStatus.reason}')
        CYCLE_RETAINED_COUNT=$(configmap_flood_count)
        CYCLE_LIMIT=$(fleet_target_kubectl get deployment/demo-controllers-controller -n "${NAMESPACE}" \
            -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)
        CYCLE_ALERT_ACTIVE=false
        _cycle_alert_cluster="${SPOKE_CLUSTER_LABEL:-${FLEET_CLUSTER_ID:-remote-cluster}}"
        if fleet_alert_present "KubePodCrashLooping" "${NAMESPACE}" "${_cycle_alert_cluster}"; then
            CYCLE_ALERT_ACTIVE=true
        fi

        echo "  RR cycle=${cycle} name=${NEXT_RR} phase=${CYCLE_PHASE} outcome=${CYCLE_OUTCOME} reason=${CYCLE_AA_REASON:-${CYCLE_AA_SUBREASON:-${CYCLE_BLOCK_REASON:-${CYCLE_ROUTING_REASON:-none}}}} retainedConfigMaps=${CYCLE_RETAINED_COUNT} limit=${CYCLE_LIMIT}"
        assert_eq "${CYCLE_POLL_RC}" "0" "RR cycle ${cycle} reached a terminal platform decision"
        assert_eq "${CYCLE_PHASE}" "Completed" "RR cycle ${cycle} phase"
        assert_eq "${CYCLE_ALERT_ACTIVE}" "true" "KubePodCrashLooping remained active at RR cycle ${cycle}"
        assert_gt "${CYCLE_RETAINED_COUNT}" $((INITIAL_FLOOD_COUNT - 1)) "stimulus retained through RR cycle ${cycle}"

        CYCLE_ESCALATION_TEXT="${CYCLE_AA_REASON} ${CYCLE_AA_SUBREASON} ${CYCLE_BLOCK_REASON} ${CYCLE_ROUTING_REASON}"
        if [ "${CYCLE_OUTCOME}" = "ManualReviewRequired" ] || \
           [ "${CYCLE_REQUIRES_REVIEW}" = "true" ]; then
            assert_eq "${CYCLE_OUTCOME}" "ManualReviewRequired" \
                "RR cycle ${cycle} escalated to ManualReviewRequired"
            assert_eq "${CYCLE_AA_PHASE}" "Completed" "RR cycle ${cycle} AA phase at escalation"
            assert_eq "${CYCLE_REQUIRES_REVIEW}" "true" "RR cycle ${cycle} requires manual review"
            assert_eq "${CYCLE_AA_WORKFLOW}" "" "RR cycle ${cycle} selected no remediation workflow"
            assert_eq "${CYCLE_LIMIT}" "${LAST_LIMIT}" \
                "RR cycle ${cycle} escalation did not increase Deployment memory"
            if platform_escalation_evidence "${CYCLE_ESCALATION_TEXT}"; then
                assert_eq "true" "true" "RR cycle ${cycle} reason cites platform history/routing"
            else
                assert_eq "true" "false" "RR cycle ${cycle} reason cites platform history/routing"
            fi

            CYCLE_WFE_EXISTS=false
            if workflow_execution_exists_for_rr "${NEXT_RR}"; then
                CYCLE_WFE_EXISTS=true
            fi
            CYCLE_RAR_EXISTS=false
            if approval_request_exists_for_rr "${NEXT_RR}"; then
                CYCLE_RAR_EXISTS=true
            fi
            assert_eq "${CYCLE_WFE_EXISTS}" "false" \
                "RR cycle ${cycle} escalation created no WorkflowExecution"
            assert_eq "${CYCLE_RAR_EXISTS}" "false" \
                "RR cycle ${cycle} escalation created no RAR"

            start_gitea_port_forward
            GITEA_JSON_DIR=$(mktemp -d)
            CYCLE_PULLS_FILE="${GITEA_JSON_DIR}/pulls.json"
            gitea_pull_count "${CYCLE_PULLS_FILE}" >/dev/null
            CYCLE_PR_COUNT=$(jq 'length' "${CYCLE_PULLS_FILE}" 2>/dev/null || echo "-1")
            assert_eq "${GITEA_PULL_COUNT_CODE}" "200" \
                "Gitea pull-request listing after RR cycle ${cycle} escalation"
            assert_eq "${CYCLE_PR_COUNT}" "${EXPECTED_PR_COUNT}" \
                "RR cycle ${cycle} escalation created no additional Gitea pull request"
            rm -rf "${GITEA_JSON_DIR}"
            cleanup_gitea_port_forward

            AUDIT_TRACE_FILE="$(mktemp -t operator-oomkill-audit.XXXXXX)"
            if bash "${REPO_ROOT}/scripts/extract-audit-trace.sh" --fleet "${NEXT_RR}" --json --investigation >"${AUDIT_TRACE_FILE}" 2>&1; then
                history_evidence=$(grep -Eio 'remediation_history|regression_detected|previous remediation|prior remediation|ineffective' "${AUDIT_TRACE_FILE}" | head -1 || true)
                assert_neq "${history_evidence}" "" \
                    "RR cycle ${cycle} audit contains remediation history evidence"
                history_chain_metrics=$(history_chain_metrics_from_audit "${AUDIT_TRACE_FILE}")
                IFS=$'\t' read -r history_entry_count history_link_count <<<"${history_chain_metrics}"
                assert_gt "${history_entry_count}" $((OBSERVED_REMEDIATIONS - 1)) \
                    "RR cycle ${cycle} audit includes prior failed remediations"
                if [ "${OBSERVED_REMEDIATIONS}" -gt 1 ]; then
                    assert_gt "${history_link_count}" $((OBSERVED_REMEDIATIONS - 2)) \
                        "RR cycle ${cycle} audit preserves remediation hash links"
                fi
                echo "  Audit trace captured at ${AUDIT_TRACE_FILE}; linked history entries=${history_entry_count}, hash links=${history_link_count}"
            else
                echo "WARNING: could not extract the DataStorage audit trace; see ${AUDIT_TRACE_FILE}" >&2
                assert_neq "" "" "DataStorage audit trace extraction at RR cycle ${cycle}"
            fi
            ESCALATION_FOUND=true
            break
        fi

        # If routing has not escalated yet, this recurrence must be another
        # ineffective, human-gated execution of the same pinned workflow.
        CYCLE_EXPECTED_LIMIT="$((128 * (cycle + 1)))Mi"
        CYCLE_EA_PHASE=$(jsonpath_or_empty effectivenessassessments "ea-${NEXT_RR}" "${PLATFORM_NS}" '{.status.phase}')
        CYCLE_EA_HEALTH=$(jsonpath_or_empty effectivenessassessments "ea-${NEXT_RR}" "${PLATFORM_NS}" '{.status.components.healthScore}')
        CYCLE_EA_ALERT=$(jsonpath_or_empty effectivenessassessments "ea-${NEXT_RR}" "${PLATFORM_NS}" '{.status.components.alertScore}')
        CYCLE_RAR_DECISION=$(jsonpath_or_empty remediationapprovalrequest "rar-${NEXT_RR}" "${PLATFORM_NS}" '{.status.decision}')
        CYCLE_RAR_DECIDED_BY=$(jsonpath_or_empty remediationapprovalrequest "rar-${NEXT_RR}" "${PLATFORM_NS}" '{.status.decidedBy}')
        CYCLE_WFE_EXISTS=false
        if workflow_execution_exists_for_rr "${NEXT_RR}"; then
            CYCLE_WFE_EXISTS=true
        fi
        CYCLE_WFE_NAME="we-${NEXT_RR}"
        CYCLE_WFE_CLUSTER=$(jsonpath_or_empty workflowexecutions "${CYCLE_WFE_NAME}" "${PLATFORM_NS}" '{.spec.clusterID}')

        assert_eq "${CYCLE_OUTCOME}" "Inconclusive" \
            "RR cycle ${cycle} outcome (ineffective remediation)"
        assert_eq "${CYCLE_AA_PHASE}" "Completed" "RR cycle ${cycle} AA phase"
        assert_contains "${CYCLE_AA_BUNDLE}" "increase-memory-limits-gitops-job" \
            "RR cycle ${cycle} selected the pinned GitOps workflow"
        assert_eq "${CYCLE_WFE_EXISTS}" "true" "RR cycle ${cycle} created a WorkflowExecution"
        if [ "${FLEET_MODE:-false}" = true ]; then
            assert_eq "${CYCLE_WFE_CLUSTER}" "hub" "RR cycle ${cycle} workflow execution cluster"
        fi
        assert_eq "${CYCLE_RAR_DECISION}" "Approved" "RR cycle ${cycle} RAR decision"
        assert_neq "${CYCLE_RAR_DECIDED_BY}" "" "RR cycle ${cycle} RAR decision actor"
        assert_eq "${CYCLE_LIMIT}" "${CYCLE_EXPECTED_LIMIT}" \
            "RR cycle ${cycle} applied exactly one additional +128Mi increment"
        assert_eq "${CYCLE_EA_PHASE}" "Completed" "RR cycle ${cycle} effectiveness assessment phase"
        if is_zero_score "${CYCLE_EA_ALERT}"; then
            CYCLE_FAILURE_EVIDENCE="alertScore=${CYCLE_EA_ALERT}"
        elif is_zero_score "${CYCLE_EA_HEALTH}"; then
            CYCLE_FAILURE_EVIDENCE="healthScore=${CYCLE_EA_HEALTH}"
        else
            CYCLE_FAILURE_EVIDENCE=""
        fi
        assert_neq "${CYCLE_FAILURE_EVIDENCE}" "" \
            "RR cycle ${cycle} has alert/health failure evidence"

        # Every permitted remediation remains a separately reviewed GitOps
        # change. The workflow never decides that recurrence should escalate.
        CYCLE_MERGED_SHA=$(printf '%s\n' "${JOB_LOG}" | sed -n 's/^PR_MERGED_COMMIT_SHA=//p' | tail -1)
        CYCLE_PR_NUMBER=$(printf '%s\n' "${JOB_LOG}" | sed -n 's/^FORWARD_CHANGE_PR_NUMBER=//p' | tail -1)
        CYCLE_PR_URL=$(printf '%s\n' "${JOB_LOG}" | sed -n 's/^FORWARD_CHANGE_PR_URL=//p' | tail -1)
        CYCLE_PR_MERGED_BY=$(printf '%s\n' "${JOB_LOG}" | sed -n 's/^PR_MERGED_BY=//p' | tail -1)
        assert_contains "${JOB_LOG}" "FORWARD_CHANGE_PR_URL" \
            "RR cycle ${cycle} forward-change PR is observable"
        assert_contains "${JOB_LOG}" "PR_STATE=merged" \
            "RR cycle ${cycle} Job waited for the human PR merge"
        CYCLE_FORBIDDEN_ACTIONS=$(printf '%s' "${JOB_LOG}" | grep -Ei '/pulls/.*/merge|git push .* main|kubectl .* (patch|apply|edit)' || true)
        assert_eq "${CYCLE_FORBIDDEN_ACTIONS}" "" \
            "RR cycle ${cycle} workflow log contains no direct mutation or auto-merge"
        assert_neq "${CYCLE_MERGED_SHA}" "" "RR cycle ${cycle} merged PR commit SHA recorded"
        assert_neq "${CYCLE_PR_NUMBER}" "" "RR cycle ${cycle} PR number recorded"
        assert_neq "${CYCLE_PR_URL}" "" "RR cycle ${cycle} PR URL recorded"
        assert_eq "${CYCLE_PR_MERGED_BY}" "${GITEA_REVIEWER}" \
            "RR cycle ${cycle} protected PR was merged by the reviewer"

        start_gitea_port_forward
        GITEA_JSON_DIR=$(mktemp -d)
        CYCLE_REVIEWS_FILE="${GITEA_JSON_DIR}/reviews.json"
        CYCLE_PULLS_FILE="${GITEA_JSON_DIR}/pulls.json"
        CYCLE_REVIEWS_CODE=$(gitea_get_json "/repos/${GITEA_USER}/${GITEA_REPO}/pulls/${CYCLE_PR_NUMBER}/reviews" "${CYCLE_REVIEWS_FILE}")
        gitea_pull_count "${CYCLE_PULLS_FILE}" >/dev/null
        CYCLE_PR_COUNT=$(jq 'length' "${CYCLE_PULLS_FILE}" 2>/dev/null || echo "-1")
        CYCLE_HUMAN_APPROVALS=$(jq --arg reviewer "${GITEA_REVIEWER}" \
            '[.[] | select((.state | ascii_upcase) == "APPROVED" and .user.login == $reviewer)] | length' \
            "${CYCLE_REVIEWS_FILE}" 2>/dev/null || echo "0")
        assert_eq "${CYCLE_REVIEWS_CODE}" "200" \
            "RR cycle ${cycle} Gitea PR reviews API response"
        assert_eq "${GITEA_PULL_COUNT_CODE}" "200" \
            "RR cycle ${cycle} Gitea pull-request listing API response"
        assert_gt "${CYCLE_PR_COUNT}" "${EXPECTED_PR_COUNT}" \
            "RR cycle ${cycle} created one additional Gitea pull request"
        assert_gt "${CYCLE_HUMAN_APPROVALS}" "0" \
            "RR cycle ${cycle} independent human reviewer approved the PR"
        EXPECTED_PR_COUNT="${CYCLE_PR_COUNT}"
        rm -rf "${GITEA_JSON_DIR}"
        cleanup_gitea_port_forward

        CYCLE_APP_REVISION=$(wait_for_argocd_revision "${CYCLE_MERGED_SHA}" 360 2>/dev/null || true)
        assert_neq "${CYCLE_APP_REVISION}" "" "RR cycle ${cycle} Argo CD applied revision"
        if [ -n "${CYCLE_APP_REVISION}" ]; then
            assert_eq "${CYCLE_APP_REVISION}" "${CYCLE_MERGED_SHA}" \
                "RR cycle ${cycle} Argo CD applied merged revision"
        fi

        OBSERVED_REMEDIATIONS=$((OBSERVED_REMEDIATIONS + 1))
        LAST_RR="${NEXT_RR}"
        LAST_RR_CREATED_AT=$(jsonpath_or_empty remediationrequests "${LAST_RR}" "${PLATFORM_NS}" '{.metadata.creationTimestamp}')
        LAST_LIMIT="${CYCLE_LIMIT}"
    done

    assert_eq "${ESCALATION_FOUND}" "true" \
        "platform escalated the continuing ineffective chain within ${MAX_RR_CYCLES} RR cycles"
fi

# Only after first-cycle EA and recurrence/escalation evidence have been
# captured is it safe to remove the stimulus.
cleanup_stimulus
unset VALIDATION_RR_NAME

print_result "operator-oomkill-informer"
