#!/usr/bin/env bash
# Cleanup for Operator OOMKill Informer Cache Flooding scenario
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-controllers"
# shellcheck source=../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"

# Delete the attack ConfigMaps before deleting the namespace. Namespace
# deletion asks the apiserver to enumerate and remove every object at once;
# hundreds of ~1MiB ConfigMaps can make that request time out and leave the
# namespace stuck in Terminating. Delete only the scenario-owned flood objects
# in small, non-blocking batches so cleanup remains safe for shared resources.
delete_flood_configmaps() {
    local names=() elapsed=0
    while [ "$elapsed" -lt 120 ]; do
        names=()
        while IFS= read -r name; do
            [ -n "$name" ] && names+=("$name")
        done < <(
            fleet_target_kubectl get configmaps -n "$NAMESPACE" \
                -o name 2>/dev/null \
                | awk -F/ '$2 ~ /^app-config-[0-9]+$/ { print $0 }' \
                | head -n 20
        )
        [ "${#names[@]}" -gt 0 ] || break
        fleet_target_kubectl delete "${names[@]}" -n "$NAMESPACE" \
            --ignore-not-found --wait=false >/dev/null 2>&1 || true
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if [ "$elapsed" -ge 120 ]; then
        echo "  WARNING: flood ConfigMaps still deleting after 120s; continuing with namespace cleanup..." >&2
    fi
}

# A failed workflow execution can retain its cleanup finalizer while the
# execution Job still exists. This scenario owns the target Deployment, so it
# is safe to remove only Jobs/WFEs for that exact target before/after the
# scoped pipeline purge; never touch workflow executions for other scenarios.
scenario_workflow_executions() {
    kubectl get workflowexecutions -n "${PLATFORM_NS:-kubernaut-system}" -o json 2>/dev/null \
        | jq -r --arg target "${NAMESPACE}/Deployment/demo-controllers-controller" \
            '.items[] | select(.spec.targetResource == $target) | .metadata.name' \
        2>/dev/null || true
}

delete_scenario_workflow_jobs() {
    local wfe_name job_name
    while IFS= read -r wfe_name; do
        [ -n "${wfe_name}" ] || continue
        job_name=$(kubectl get workflowexecution "${wfe_name}" \
            -n "${PLATFORM_NS:-kubernaut-system}" \
            -o jsonpath='{.status.executionRef.name}' 2>/dev/null || true)
        [ -n "${job_name}" ] || continue
        kubectl delete job "${job_name}" -n "${WE_NAMESPACE:-kubernaut-workflows}" \
            --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done < <(scenario_workflow_executions)
}

clear_scenario_workflow_finalizers() {
    local wfe_name
    while IFS= read -r wfe_name; do
        [ -n "${wfe_name}" ] || continue
        kubectl patch workflowexecution "${wfe_name}" \
            -n "${PLATFORM_NS:-kubernaut-system}" --type=merge \
            -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        kubectl delete workflowexecution "${wfe_name}" \
            -n "${PLATFORM_NS:-kubernaut-system}" \
            --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done < <(scenario_workflow_executions)
}

if fleet_initialize_targeting "$@"; then
    # Operator workload and monitoring resources are spoke-side; pipeline
    # state is hub-side.
    # shellcheck source=../../scripts/platform-helper.sh
    source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

    ARGOCD_NS=$(get_argocd_namespace)
    APP_NAME="${OPERATOR_GITOPS_APP_NAME:-operator-oomkill-informer}"
    REPO_NAME="${OPERATOR_GITOPS_REPO:-demo-operator-oomkill-repo}"
    GITEA_NAMESPACE="gitea"
    GITEA_USER="${GITEA_ADMIN_USER:-kubernaut}"
    GITEA_PASS="${GITEA_ADMIN_PASS:-kubernaut123}"
    _cleanup_pf_pid=""

    cleanup_fleet_exit() {
        if [ -n "${_cleanup_pf_pid}" ]; then
            kill "${_cleanup_pf_pid}" 2>/dev/null || true
        fi
        restore_gateway_deduplication_cooldown || true
        restore_ro_gitops_sync_delay || true
        restore_production_approval || true
    }
    trap cleanup_fleet_exit EXIT

    echo "==> [hub] Removing the operator Argo CD Application..."
    kubectl delete application "${APP_NAME}" -n "${ARGOCD_NS}" \
        --ignore-not-found --wait=true 2>/dev/null || true

    # The repository is scenario-owned. Keep the shared Gitea installation,
    # reviewer account, repo-credential Secret, and Argo cluster registration.
    # Deleting only this repository makes the next rehearsal start from a
    # clean protected-main history without disturbing other GitOps demos.
    if kubectl get service gitea-http -n "${GITEA_NAMESPACE}" &>/dev/null; then
        kill_stale_gitea_pf 2>/dev/null || true
        kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http \
            "${GITEA_LOCAL_PORT}:3000" &>/dev/null &
        _cleanup_pf_pid=$!
        if wait_for_port "${GITEA_LOCAL_PORT}" 30; then
            curl -sS -o /dev/null \
                -u "${GITEA_USER}:${GITEA_PASS}" -X DELETE \
                "http://localhost:${GITEA_LOCAL_PORT}/api/v1/repos/${GITEA_USER}/${REPO_NAME}" \
                || true
        fi
        kill "${_cleanup_pf_pid}" 2>/dev/null || true
        _cleanup_pf_pid=""
    fi

    restore_gateway_deduplication_cooldown || true
    restore_ro_gitops_sync_delay || true
    restore_production_approval || true
    delete_flood_configmaps
    fleet_cleanup_scenario_resources "${SCRIPT_DIR}/manifests" "$NAMESPACE"
    delete_scenario_workflow_jobs
    purge_pipeline_crds
    clear_scenario_workflow_finalizers
    exit 0
fi
# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

namespace_exists() {
    kubectl get ns "$1"
}

echo "==> Cleaning up Operator OOMKill Informer demo..."

if [ "${PLATFORM:-kind}" = "ocp" ]; then
    kubectl delete prometheusrule demo-controllers-rules-operator -n openshift-monitoring --ignore-not-found
    kubectl delete prometheusrule demo-controllers-rules -n openshift-monitoring --ignore-not-found
else
    kubectl delete prometheusrule demo-controllers-rules -n demo-controllers --ignore-not-found
fi
delete_flood_configmaps
kubectl delete namespace demo-controllers --ignore-not-found --wait=false
restore_gateway_deduplication_cooldown || true
restore_ro_gitops_sync_delay || true

echo "==> Waiting for namespace deletion to complete..."
_elapsed=0
while namespace_exists demo-controllers &>/dev/null; do
    sleep 2
    _elapsed=$((_elapsed + 2))
    if [ "$_elapsed" -ge 120 ]; then
        echo "  WARNING: Namespace still terminating after 120s, proceeding..."
        break
    fi
done

purge_pipeline_crds

echo "==> Cleanup complete."
