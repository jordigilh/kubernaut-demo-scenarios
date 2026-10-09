#!/usr/bin/env bash
# Operator OOMKill from Informer Cache Flooding -- GitOps Fleet Hub
# Based on kubeflow/spark-operator#2878; issue #446.
#
# The hub owns Gitea, Argo CD, the repository credential, and the Kubernaut
# control plane. The spoke owns the operator, its signal, and recovery
# evidence. The operator manifests are seeded into Git and applied by Argo CD.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENARIO_DIR="${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NAMESPACE="demo-controllers"
GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-kubernaut}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-kubernaut123}"
GITEA_REVIEWER_USER="${GITEA_REVIEWER_USER:-sre-reviewer}"
GITEA_REVIEWER_PASS="${GITEA_REVIEWER_PASS:-sre-reviewer123}"
GITEA_REVIEWER_EMAIL="${GITEA_REVIEWER_EMAIL:-sre-reviewer@kubernaut.ai}"
REPO_NAME="${OPERATOR_GITOPS_REPO:-demo-operator-oomkill-repo}"
APP_NAME="${OPERATOR_GITOPS_APP_NAME:-operator-oomkill-informer}"
INITIAL_FLOOD_COUNT="${INITIAL_FLOOD_COUNT:-300}"
# Argo CD is refreshed by the Gitea push webhook, so the default polling-oriented
# propagation delay can be shorter for this scenario. Keep the override for
# environments that need a different run-scoped value. The full stabilization
# window gives the retained informer load time to expose a delayed ineffective
# remediation; cleanup restores the original values.
GITOPS_SYNC_DELAY="${GITOPS_SYNC_DELAY:-10s}"
EFFECTIVENESS_STABILIZATION_WINDOW="${EFFECTIVENESS_STABILIZATION_WINDOW:-5m}"
GATEWAY_DEDUP_COOLDOWN="${GATEWAY_DEDUP_COOLDOWN:-0s}"
APPROVE_MODE="--interactive"
ALERT_ONLY=false
NO_VALIDATE=false

# The shared GitOps installers are invoked as child processes. Export the
# scenario-owned values so a custom repository or platform-specific port is
# provisioned consistently instead of silently falling back to demo-gitops-repo
# and the default credentials.
export GITEA_ADMIN_USER GITEA_ADMIN_PASS GITEA_REVIEWER_USER REPO_NAME

for _arg in "$@"; do
    case "${_arg}" in
        --auto-approve) APPROVE_MODE="--auto-approve" ;;
        --interactive)  APPROVE_MODE="--interactive" ;;
        --alert-only)   ALERT_ONLY=true ;;
        --no-validate)  NO_VALIDATE=true ;;
        --fleet)        ;;
        *) echo "WARNING: ignoring unsupported fleet argument ${_arg}" >&2 ;;
    esac
done

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity
fleet_check_spoke_connectivity

export KUBECONFIG="${HUB_KUBECONFIG}"
# shellcheck source=../../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

export OPERATOR_GITOPS_APP_NAME="${APP_NAME}"
export OPERATOR_GITOPS_REPO="${REPO_NAME}"
export OPERATOR_GITOPS_NAMESPACE="${NAMESPACE}"
export INITIAL_FLOOD_COUNT

GITEA_API="http://localhost:${GITEA_LOCAL_PORT}/api/v1"
GITEA_IN_CLUSTER_URL="http://gitea-http.${GITEA_NAMESPACE}:3000"
PF_PID=""
WORK_DIR=""

cleanup_port_forward() {
    if [ -n "${PF_PID}" ]; then
        kill "${PF_PID}" 2>/dev/null || true
        PF_PID=""
    fi
}
cleanup_run() {
    [ -n "${WORK_DIR}" ] && rm -rf "${WORK_DIR}"
    cleanup_port_forward
    # The delay is a run-scoped tuning knob. Restore it even when setup or
    # validation exits early, rather than relying on a later manual cleanup.
    if [ "${DEFER_FLEET_TUNING_RESTORE:-false}" != true ]; then
        restore_gateway_deduplication_cooldown || true
        restore_ro_gitops_sync_delay || true
        restore_production_approval || true
    fi
}
trap cleanup_run EXIT

start_gitea_port_forward() {
    cleanup_port_forward
    kill_stale_gitea_pf
    kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http \
        "${GITEA_LOCAL_PORT}:3000" &>/dev/null &
    PF_PID=$!
    wait_for_port "${GITEA_LOCAL_PORT}" 45
}

# Prints only the HTTP status and optionally writes the response to $4.
gitea_api_code() {
    local method="$1" path="$2" body="${3:-}" output="${4:-/dev/null}"
    local args=(-sS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
        -o "${output}" -w '%{http_code}' -X "${method}")
    if [ -n "${body}" ]; then
        args+=(-H 'Content-Type: application/json' -d "${body}")
    fi
    curl "${args[@]}" "${GITEA_API}${path}" || true
}


# Provisional demo tuning only. The RO's existing async propagation mechanism
# remains authoritative; cleanup.sh restores the original values.
force_production_approval
configure_gateway_deduplication_cooldown "${GATEWAY_DEDUP_COOLDOWN}"
configure_ro_gitops_timing "${GITOPS_SYNC_DELAY}" "${EFFECTIVENESS_STABILIZATION_WINDOW}"

echo "==> [hub=${HUB_KUBECONFIG}] Ensuring Gitea + Argo CD are installed..."
if ! kubectl get service gitea-http -n "${GITEA_NAMESPACE}" &>/dev/null; then
    bash "${SCRIPT_DIR}/../gitops/scripts/setup-gitea.sh"
fi
ARGOCD_NS=$(get_argocd_namespace)
ARGOCD_SERVER_SVC=$(get_argocd_server_svc)
if ! kubectl get service "${ARGOCD_SERVER_SVC}" -n "${ARGOCD_NS}" &>/dev/null; then
    bash "${SCRIPT_DIR}/../gitops/scripts/setup-argocd.sh"
fi
export ARGOCD_NAMESPACE="${ARGOCD_NS}"

# setup-demo-cluster normally creates these objects, but make the scenario
# self-contained when it is run against an existing hub. The repo-creds URL is
# host-scoped so Argo CD can read the scenario-owned repository created below.
kubectl create namespace "${ARGOCD_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f - <<EOF_CREDS
apiVersion: v1
kind: Secret
metadata:
  name: gitea-repo-creds
  namespace: ${ARGOCD_NS}
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: http://gitea-http.${GITEA_NAMESPACE}:3000
  username: ${GITEA_ADMIN_USER}
  password: ${GITEA_ADMIN_PASS}
EOF_CREDS
kubectl create namespace "${WE_NAMESPACE:-kubernaut-workflows}" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null
kubectl apply -f - <<EOF_WORKFLOW_CREDS
apiVersion: v1
kind: Secret
metadata:
  name: gitea-repo-creds
  namespace: ${WE_NAMESPACE:-kubernaut-workflows}
  labels:
    kubernaut.ai/dependency-type: git-credentials
stringData:
  username: ${GITEA_ADMIN_USER}
  password: ${GITEA_ADMIN_PASS}
EOF_WORKFLOW_CREDS

echo "==> [hub] Seeding the GitOps workflow catalog entry and hub runner RBAC..."
HUB_KUBECONFIG="${HUB_KUBECONFIG}" SPOKE_KUBECONFIG="${SPOKE_KUBECONFIG}" \
    bash "${REPO_ROOT}/scripts/seed-workflows.sh" \
    --scenario operator-oomkill-informer --continue-on-error

echo "==> [hub] Registering spoke as the Argo CD destination..."
SPOKE_SERVER=$(fleet_register_argocd_spoke_cluster "spoke" "${ARGOCD_NS}")
HUB_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
if [ -z "${SPOKE_SERVER}" ] || [ "${SPOKE_SERVER}" = "${HUB_SERVER}" ] || \
   [ "${SPOKE_SERVER}" = "https://kubernetes.default.svc" ]; then
    echo "ERROR: Argo CD spoke registration resolved to the hub (${SPOKE_SERVER:-empty})." >&2
    exit 1
fi

echo "==> [hub] Removing stale Application and spoke namespace..."
kubectl delete application "${APP_NAME}" -n "${ARGOCD_NS}" --ignore-not-found --wait=true
kubectl --kubeconfig="${SPOKE_KUBECONFIG}" delete namespace "${NAMESPACE}" \
    --ignore-not-found --wait=true

echo "==> [hub] Creating a clean GitOps repository for this run..."
start_gitea_port_forward
# Setup-time reset occurs before protection; the remediation Job cannot do this.
DELETE_CODE=$(gitea_api_code DELETE "/repos/${GITEA_ADMIN_USER}/${REPO_NAME}")
if [ "${DELETE_CODE}" != "204" ] && [ "${DELETE_CODE}" != "404" ]; then
    echo "ERROR: unable to reset Gitea repository ${REPO_NAME} (HTTP ${DELETE_CODE})." >&2
    exit 1
fi
for _i in $(seq 1 20); do
    GET_CODE=$(gitea_api_code GET "/repos/${GITEA_ADMIN_USER}/${REPO_NAME}")
    [ "${GET_CODE}" = "404" ] && break
    sleep 1
done
CREATE_BODY=$(jq -n --arg name "${REPO_NAME}" \
    '{name:$name, auto_init:false, private:false, description:"Operator OOM GitOps demo repository"}')
CREATE_CODE=$(gitea_api_code POST "/user/repos" "${CREATE_BODY}")
[ "${CREATE_CODE}" = "201" ] || {
    echo "ERROR: unable to create Gitea repository ${REPO_NAME} (HTTP ${CREATE_CODE})." >&2
    exit 1
}

echo "==> [hub] Seeding healthy operator manifests before enabling protection..."
WORK_DIR=$(mktemp -d)
mkdir -p "${WORK_DIR}/repo/manifests" "${WORK_DIR}/repo/overlays"
cp -R "${SCENARIO_DIR}/manifests/." "${WORK_DIR}/repo/manifests/"
if [ -d "${SCENARIO_DIR}/overlays/ocp" ]; then
    mkdir -p "${WORK_DIR}/repo/overlays/ocp"
    cp -R "${SCENARIO_DIR}/overlays/ocp/." "${WORK_DIR}/repo/overlays/ocp/"
fi

# Alert labels must survive the spoke -> Thanos/Alertmanager path. Render the
# registered spoke identity into the desired PrometheusRule before the initial
# commit; patching the live rule after Argo sync would be immediately reverted.
SPOKE_CLUSTER_ID=$(fleet_cluster_id)
python3 - "${WORK_DIR}/repo/manifests/prometheus-rule.yaml" "${SPOKE_CLUSTER_ID}" <<'PY'
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
cluster = json.dumps(sys.argv[2])
text = path.read_text()
if not re.search(r"^kind:\s*PrometheusRule\s*$", text, re.M):
    raise SystemExit("expected PrometheusRule manifest")
matches = list(re.finditer(r"^([ \t]*)(cluster:)[ \t]*.*$", text, re.M))
if len(matches) > 1:
    raise SystemExit(f"expected at most one PrometheusRule cluster label, found {len(matches)}")
if matches:
    match = matches[0]
    replacement = f"{match.group(1)}{match.group(2)} {cluster}"
    updated = text[:match.start()] + replacement + text[match.end():]
else:
    severity = re.search(r"^([ \t]*severity:)[ \t]*.*$", text, re.M)
    if not severity:
        raise SystemExit("expected a PrometheusRule severity label for cluster attribution")
    indent = severity.group(1)[:-len("severity:")]
    insertion = f"{severity.group(0)}\n{indent}cluster: {cluster}"
    updated = text[:severity.start()] + insertion + text[severity.end():]
path.write_text(updated)
PY

git -C "${WORK_DIR}/repo" init -b main -q
git -C "${WORK_DIR}/repo" config user.email "${GITEA_ADMIN_USER}@kubernaut.ai"
git -C "${WORK_DIR}/repo" config user.name "Kubernaut Setup"
git -C "${WORK_DIR}/repo" add .
git -C "${WORK_DIR}/repo" commit -q -m "Initial operator deployment and monitoring"
git -C "${WORK_DIR}/repo" remote add origin \
    "http://localhost:${GITEA_LOCAL_PORT}/${GITEA_ADMIN_USER}/${REPO_NAME}.git"
SETUP_CREDENTIAL_HELPER="${WORK_DIR}/setup-credential-helper"
cat > "${SETUP_CREDENTIAL_HELPER}" <<'SETUP_CREDENTIAL_HELPER'
#!/bin/sh
if [ "${1:-}" = "get" ]; then
    printf 'username=%s\n' "${GIT_USERNAME}"
    printf 'password=%s\n' "${GIT_PASSWORD}"
fi
SETUP_CREDENTIAL_HELPER
chmod 700 "${SETUP_CREDENTIAL_HELPER}"
GIT_USERNAME="${GITEA_ADMIN_USER}" GIT_PASSWORD="${GITEA_ADMIN_PASS}" \
    git -C "${WORK_DIR}/repo" -c "credential.helper=${SETUP_CREDENTIAL_HELPER}" \
    push -u origin main -q

SPOKE_PLATFORM=$(detect_spoke_platform)
if [ "${SPOKE_PLATFORM}" = "ocp" ]; then
    ARGO_SOURCE_PATH="overlays/ocp"
else
    ARGO_SOURCE_PATH="manifests"
fi
export ARGO_SOURCE_PATH

echo "==> [hub] Creating reviewer account and repository access..."
REVIEWER_BODY=$(jq -n --arg login "${GITEA_REVIEWER_USER}" \
    --arg email "${GITEA_REVIEWER_EMAIL}" --arg password "${GITEA_REVIEWER_PASS}" \
    '{login_name:$login, email:$email, username:$login, password:$password, must_change_password:false, send_notify:false}')
REVIEWER_CODE=$(gitea_api_code POST "/admin/users" "${REVIEWER_BODY}")
if [ "${REVIEWER_CODE}" != "201" ] && [ "${REVIEWER_CODE}" != "409" ] && [ "${REVIEWER_CODE}" != "422" ]; then
    echo "ERROR: unable to create reviewer account (HTTP ${REVIEWER_CODE})." >&2
    exit 1
fi
COLLABORATOR_CODE=$(gitea_api_code PUT \
    "/repos/${GITEA_ADMIN_USER}/${REPO_NAME}/collaborators/${GITEA_REVIEWER_USER}" \
    '{"permission":"write"}')
[ "${COLLABORATOR_CODE}" = "204" ] || {
    echo "ERROR: unable to grant ${GITEA_REVIEWER_USER} write access (HTTP ${COLLABORATOR_CODE})." >&2
    exit 1
}

echo "==> [hub] Protecting main: no direct pushes, one independent approval..."
PROTECTION_BODY=$(jq -n --arg reviewer "${GITEA_REVIEWER_USER}" \
    '{branch_name:"main", enable_push:false, enable_force_push:false,
      required_approvals:1, dismiss_stale_approvals:true,
      block_on_outdated_branch:true, block_on_rejected_reviews:true,
      block_admin_merge_override:true, enable_approvals_whitelist:true,
      approvals_whitelist_username:[$reviewer], enable_merge_whitelist:true,
      merge_whitelist_usernames:[$reviewer]}')
PROTECTION_CODE=$(gitea_api_code POST \
    "/repos/${GITEA_ADMIN_USER}/${REPO_NAME}/branch_protections" \
    "${PROTECTION_BODY}")
[ "${PROTECTION_CODE}" = "201" ] || {
    echo "ERROR: unable to protect main (HTTP ${PROTECTION_CODE})." >&2
    exit 1
}
PROTECTION_JSON="${WORK_DIR}/branch-protection.json"
PROTECTION_GET_CODE=$(gitea_api_code GET \
    "/repos/${GITEA_ADMIN_USER}/${REPO_NAME}/branch_protections/main" "" "${PROTECTION_JSON}")
[ "${PROTECTION_GET_CODE}" = "200" ] || {
    echo "ERROR: unable to read back main branch protection (HTTP ${PROTECTION_GET_CODE})." >&2
    exit 1
}
jq -e --arg reviewer "${GITEA_REVIEWER_USER}" \
    '(.enable_push == false) and (.required_approvals >= 1) and
     (.block_admin_merge_override == true) and
     (.approvals_whitelist_username | index($reviewer)) and
     (.merge_whitelist_usernames | index($reviewer))' \
    "${PROTECTION_JSON}" >/dev/null || {
    echo "ERROR: Gitea main branch protection did not enforce the required PR gate." >&2
    exit 1
}

echo "==> [hub] Enabling push webhook to Argo CD..."
ARGOCD_WEBHOOK_PORT=$(kubectl get service "${ARGOCD_SERVER_SVC}" -n "${ARGOCD_NS}" \
    -o jsonpath='{.spec.ports[0].port}')
if [ "${ARGOCD_WEBHOOK_PORT}" = "443" ]; then
    ARGOCD_WEBHOOK_SCHEME="https"
else
    ARGOCD_WEBHOOK_SCHEME="http"
fi
if [ "${ARGOCD_WEBHOOK_PORT}" = "80" ] || [ -z "${ARGOCD_WEBHOOK_PORT}" ]; then
    ARGOCD_WEBHOOK_AUTHORITY="${ARGOCD_SERVER_SVC}.${ARGOCD_NS}.svc.cluster.local"
else
    ARGOCD_WEBHOOK_AUTHORITY="${ARGOCD_SERVER_SVC}.${ARGOCD_NS}.svc.cluster.local:${ARGOCD_WEBHOOK_PORT}"
fi
WEBHOOK_URL="${ARGOCD_WEBHOOK_SCHEME}://${ARGOCD_WEBHOOK_AUTHORITY}/api/webhook"
HOOKS_JSON="${WORK_DIR}/hooks.json"
HOOKS_CODE=$(gitea_api_code GET "/repos/${GITEA_ADMIN_USER}/${REPO_NAME}/hooks" "" "${HOOKS_JSON}")
[ "${HOOKS_CODE}" = "200" ] || {
    echo "ERROR: unable to inspect Gitea webhooks (HTTP ${HOOKS_CODE})." >&2
    exit 1
}
if ! jq -e --arg url "${WEBHOOK_URL}" \
    'any(.[]; .active == true and .config.url == $url)' "${HOOKS_JSON}" >/dev/null; then
    HOOK_BODY=$(jq -n --arg url "${WEBHOOK_URL}" \
        '{type:"gitea", active:true, config:{url:$url, content_type:"json"}, events:["push"]}')
    HOOK_CODE=$(gitea_api_code POST "/repos/${GITEA_ADMIN_USER}/${REPO_NAME}/hooks" "${HOOK_BODY}")
    [ "${HOOK_CODE}" = "201" ] || {
        echo "ERROR: unable to create required Gitea -> Argo CD webhook (HTTP ${HOOK_CODE})." >&2
        exit 1
    }
fi
cleanup_port_forward
rm -rf "${WORK_DIR}"
WORK_DIR=""

echo "==> [hub] Creating Argo CD Application (${ARGO_SOURCE_PATH} -> spoke)..."
GITEA_IN_CLUSTER_URL="http://gitea-http.${GITEA_NAMESPACE}:3000"
kubectl apply -f - <<EOF_APP
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${ARGOCD_NS}
  labels:
    kubernaut.ai/demo: operator-oomkill-informer
spec:
  project: default
  source:
    repoURL: ${GITEA_IN_CLUSTER_URL}/${GITEA_ADMIN_USER}/${REPO_NAME}.git
    targetRevision: main
    path: ${ARGO_SOURCE_PATH}
  destination:
    server: ${SPOKE_SERVER}
    namespace: ${NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF_APP

APP_DESTINATION=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NS}" \
    -o jsonpath='{.spec.destination.server}')
[ "${APP_DESTINATION}" = "${SPOKE_SERVER}" ] || {
    echo "ERROR: Argo CD Application destination is ${APP_DESTINATION}, expected ${SPOKE_SERVER}." >&2
    exit 1
}

echo "==> [hub] Waiting for Argo CD to apply the healthy operator to the spoke..."
for _i in $(seq 1 60); do
    if kubectl_workload get deployment/demo-controllers-controller -n "${NAMESPACE}" &>/dev/null; then
        break
    fi
    sleep 5
done
kubectl_workload wait --for=condition=Available deployment/demo-controllers-controller \
    -n "${NAMESPACE}" --timeout=180s
echo "  Operator is healthy on the spoke with the GitOps baseline (128Mi limit)."
kubectl_workload get pods -n "${NAMESPACE}"

echo "==> [spoke] Establishing healthy baseline (15s)..."
sleep 15
echo "==> [spoke] Injecting ${INITIAL_FLOOD_COUNT} x 1MB ConfigMaps (stimulus remains during EA)..."
NAMESPACE="${NAMESPACE}" CONFIGMAP_COUNT="${INITIAL_FLOOD_COUNT}" \
    CONFIGMAP_START=1 CONFIGMAP_PREFIX=app-config KUBECONFIG="${SPOKE_KUBECONFIG}" \
    bash "${SCENARIO_DIR}/inject-configmap-flood.sh"

echo "==> [hub] Waiting for the spoke alert to arrive..."
fleet_wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 480

if [ "${ALERT_ONLY}" = true ]; then
    echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
    echo "    Application: ${APP_NAME}; repository: ${REPO_NAME}; destination: ${SPOKE_SERVER}"
    exit 0
fi
if [ "${NO_VALIDATE}" = true ]; then
    echo "==> Alert is firing; --no-validate requested, leaving the stimulus in place."
    exit 0
fi

echo "==> [hub] Starting closed-loop validation (${APPROVE_MODE})."
echo "    Gate 1: a human must approve the RemediationApprovalRequest."
echo "    Gate 2: a human must review and merge the PR."
echo "    The Job remains Running until it observes the actual merge."
bash "${SCRIPT_DIR}/fleet/validate.sh" --fleet "${APPROVE_MODE}"
