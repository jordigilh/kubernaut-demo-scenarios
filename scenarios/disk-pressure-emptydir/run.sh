#!/usr/bin/env bash
# DiskPressure emptyDir Migration Demo -- Automated Runner (Proactive)
# Scenario #324: PostgreSQL on emptyDir fills disk -> PredictedDiskPressure (proactive) ->
# SP normalizes to DiskPressure -> LLM detects antipattern -> RAR ->
# Ansible backs up DB (live pg_dump), commits PVC migration to Git ->
# ArgoCD syncs -> restore -> EA verifies
#
# Flagship enterprise demo: proactive signal (BR-SP-106) + LLM + RAR + Ansible/AAP + GitOps + audit trail
#
# Prerequisites:
#   - Kind cluster with custom kubelet eviction threshold OR OCP with kcli worker
#   - AWX deployed (run: bash scripts/awx-helper.sh)
#   - Gitea + ArgoCD deployed
#   - Prometheus with kube-state-metrics
#
# Usage:
#   ./scenarios/disk-pressure-emptydir/run.sh
#   ./scenarios/disk-pressure-emptydir/run.sh setup
#   ./scenarios/disk-pressure-emptydir/run.sh inject
#   ./scenarios/disk-pressure-emptydir/run.sh all
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-diskpressure"
GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="kubernaut"
GITEA_ADMIN_PASS="kubernaut123"
REPO_NAME="demo-diskpressure-repo"

APPROVE_MODE="--auto-approve"
SKIP_VALIDATE=""
SUBCOMMAND="all"
for _arg in "$@"; do
    case "$_arg" in
        --auto-approve)  APPROVE_MODE="--auto-approve" ;;
        --interactive)   APPROVE_MODE="--interactive" ;;
        --no-validate)   SKIP_VALIDATE=true ;;
        setup|inject|all) SUBCOMMAND="$_arg" ;;
    esac
done

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
require_demo_ready
# shellcheck source=../../scripts/monitoring-helper.sh
source "${SCRIPT_DIR}/../../scripts/monitoring-helper.sh"
require_infra awx-engine
require_infra gitea
require_infra argocd

# ── Deep preflight: verify heavy dependencies are actually healthy ───────────
_preflight_dependencies() {
    local fail=false

    # Gitea: pod must be Running + Ready, and HTTP must respond
    local gitea_ready
    gitea_ready=$(kubectl get pods -n "${GITEA_NAMESPACE}" -l app.kubernetes.io/name=gitea \
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$gitea_ready" != "True" ]; then
        echo "ERROR: Gitea pod is not Ready (status: ${gitea_ready:-not found})."
        echo "  Check: kubectl get pods -n ${GITEA_NAMESPACE}"
        fail=true
    else
        local gitea_pod
        gitea_pod=$(kubectl get pods -n "${GITEA_NAMESPACE}" -l app.kubernetes.io/name=gitea \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        local http_code
        http_code=$(kubectl exec -n "${GITEA_NAMESPACE}" "${gitea_pod}" -- \
          curl -sf -o /dev/null -w '%{http_code}' http://localhost:3000/api/v1/version 2>/dev/null || echo "000")
        if [ "$http_code" != "200" ]; then
            echo "ERROR: Gitea HTTP not responding (code: ${http_code}). Pod is Running but service is not ready."
            echo "  Check: kubectl logs -n ${GITEA_NAMESPACE} ${gitea_pod}"
            fail=true
        else
            echo "  Gitea: Ready (HTTP 200)"
        fi
    fi

    # Argo CD: server pod must be Running + Ready
    local argocd_ns
    argocd_ns=$(get_argocd_namespace 2>/dev/null || echo "openshift-gitops")
    local argocd_ready
    argocd_ready=$(kubectl get pods -n "${argocd_ns}" -l app.kubernetes.io/name=openshift-gitops-server \
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$argocd_ready" != "True" ]; then
        argocd_ready=$(kubectl get pods -n "${argocd_ns}" -l app.kubernetes.io/name=argocd-server \
          -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    fi
    if [ "$argocd_ready" != "True" ]; then
        echo "ERROR: Argo CD server pod is not Ready (status: ${argocd_ready:-not found})."
        echo "  Check: kubectl get pods -n ${argocd_ns}"
        fail=true
    else
        echo "  Argo CD: Ready"
    fi

    # AWX/AAP: controller pod must be Running + Ready
    local aap_ns="${AAP_NAMESPACE:-aap}"
    local awx_ready
    awx_ready=$(kubectl get pods -n "${aap_ns}" -l app.kubernetes.io/managed-by=automationcontroller-operator \
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$awx_ready" != "True" ]; then
        awx_ready=$(kubectl get pods -n "${aap_ns}" -l app.kubernetes.io/managed-by=awx-operator \
          -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    fi
    if [ "$awx_ready" != "True" ]; then
        echo "ERROR: AWX/AAP controller pod is not Ready (status: ${awx_ready:-not found})."
        echo "  Check: kubectl get pods -n ${aap_ns}"
        fail=true
    else
        echo "  AWX/AAP: Ready"
    fi

    # StorageClass: at least one with allowVolumeExpansion (PVC migration target)
    local sc_expand
    sc_expand=$(kubectl get sc -o jsonpath='{.items[?(@.allowVolumeExpansion==true)].metadata.name}' 2>/dev/null | awk '{print $1}')
    if [ -n "$sc_expand" ]; then
        echo "  StorageClass: ${sc_expand} (expansion enabled)"
    else
        echo "  WARNING: No StorageClass with allowVolumeExpansion found."
    fi

    if [ "$fail" = true ]; then
        echo ""
        echo "  Preflight FAILED: fix the above dependencies before running."
        exit 1
    fi
    echo "  Preflight passed."
}
echo "==> Preflight: verifying dependency health..."
_preflight_dependencies
echo ""

# Platform-specific PostgreSQL settings (top-level so both setup and inject see them)
if [ "$PLATFORM" = "ocp" ]; then
    PG_IMAGE="quay.io/sclorg/postgresql-16-c9s"
    PG_ENV_USER="POSTGRESQL_USER"
    PG_ENV_DB="POSTGRESQL_DATABASE"
    PG_ENV_PASS="POSTGRESQL_PASSWORD"
    PG_DATA_MOUNT="/var/lib/pgsql/data"
    PG_DATA_VALUE="/var/lib/pgsql/data/userdata"
else
    PG_IMAGE="postgres:16-alpine"
    PG_ENV_USER="POSTGRES_USER"
    PG_ENV_DB="POSTGRES_DB"
    PG_ENV_PASS="POSTGRES_PASSWORD"
    PG_DATA_MOUNT="/var/lib/postgresql/data"
    PG_DATA_VALUE="/var/lib/postgresql/data/pgdata"
fi

setup_gitea_argocd_webhook() {
    local repo_owner="$1" repo_name="$2"
    local argocd_ns gitea_pod argocd_svc_url webhook_secret existing_hooks
    local gitea_svc_url="http://gitea-http.${GITEA_NAMESPACE}:3000"
    local needs_restart=false

    argocd_ns=$(get_argocd_namespace)
    argocd_svc_url="https://openshift-gitops-server.${argocd_ns}.svc/api/webhook"
    if [ "$PLATFORM" != "ocp" ]; then
        argocd_svc_url="https://argocd-server.${argocd_ns}.svc/api/webhook"
    fi

    gitea_pod=$(kubectl get pods -n "${GITEA_NAMESPACE}" -l app.kubernetes.io/name=gitea \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$gitea_pod" ]; then
        echo "  WARNING: Gitea pod not found, skipping webhook setup."
        return 0
    fi

    # Gitea embeds ROOT_URL in webhook payloads. ArgoCD matches the URL
    # against Application.spec.source.repoURL. Both must agree or ArgoCD
    # silently ignores the push event. Set ROOT_URL to the in-cluster
    # service URL so the URLs match.
    local current_server_cfg
    current_server_cfg=$(kubectl get secret gitea-inline-config -n "${GITEA_NAMESPACE}" \
      -o jsonpath='{.data.server}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if ! echo "$current_server_cfg" | grep -q "ROOT_URL=${gitea_svc_url}"; then
        local gitea_domain="gitea-http.${GITEA_NAMESPACE}"
        kubectl patch secret gitea-inline-config -n "${GITEA_NAMESPACE}" --type=merge \
          -p "{\"stringData\":{\"server\":\"APP_DATA_PATH=/data\nDOMAIN=${gitea_domain}\nENABLE_PPROF=false\nHTTP_PORT=3000\nPROTOCOL=http\nROOT_URL=${gitea_svc_url}\nSSH_DOMAIN=${gitea_domain}\nSSH_LISTEN_PORT=2222\nSSH_PORT=22\nSTART_SSH_SERVER=true\"}}" 2>/dev/null
        echo "  Gitea ROOT_URL set to ${gitea_svc_url}."
        needs_restart=true
    fi

    # ArgoCD uses TLS internally; Gitea must skip certificate verification.
    local current_wh_cfg
    current_wh_cfg=$(kubectl get secret gitea-inline-config -n "${GITEA_NAMESPACE}" \
      -o jsonpath='{.data.webhook}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if ! echo "$current_wh_cfg" | grep -q "SKIP_TLS_VERIFY"; then
        kubectl patch secret gitea-inline-config -n "${GITEA_NAMESPACE}" --type=merge \
          -p '{"stringData":{"webhook":"SKIP_TLS_VERIFY=true\nALLOWED_HOST_LIST=*"}}' 2>/dev/null
        echo "  Gitea SKIP_TLS_VERIFY configured."
        needs_restart=true
    fi

    if [ "$needs_restart" = true ]; then
        kubectl rollout restart deployment/gitea -n "${GITEA_NAMESPACE}" 2>/dev/null
        kubectl rollout status deployment/gitea -n "${GITEA_NAMESPACE}" --timeout=120s 2>/dev/null
        gitea_pod=$(kubectl get pods -n "${GITEA_NAMESPACE}" -l app.kubernetes.io/name=gitea \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        echo "  Gitea restarted with updated configuration."
    fi

    # Ensure ArgoCD has a webhook.gitea.secret; generate one if missing.
    webhook_secret=$(kubectl get secret argocd-secret -n "${argocd_ns}" \
      -o jsonpath='{.data.webhook\.gitea\.secret}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ -z "$webhook_secret" ]; then
        webhook_secret=$(openssl rand -hex 20)
        kubectl patch secret argocd-secret -n "${argocd_ns}" --type=merge \
          -p "{\"stringData\":{\"webhook.gitea.secret\":\"${webhook_secret}\"}}"
        echo "  ArgoCD webhook.gitea.secret configured."
    else
        echo "  ArgoCD webhook.gitea.secret already present."
    fi

    # Create a Gitea API token via the CLI inside the pod.
    local gitea_token token_name
    token_name="kubernaut-wh-$$"
    gitea_token=$(kubectl exec -n "${GITEA_NAMESPACE}" "${gitea_pod}" -- \
      gitea admin user generate-access-token \
      -u "${repo_owner}" -t "${token_name}" \
      --scopes all --raw 2>/dev/null) || true
    if [ -z "$gitea_token" ]; then
        echo "  WARNING: Could not create Gitea token, skipping webhook setup."
        return 0
    fi

    # Delete any existing ArgoCD webhook, then recreate with the current
    # secret. This avoids stale secrets from prior runs causing silent
    # delivery failures.
    existing_hooks=$(kubectl exec -n "${GITEA_NAMESPACE}" "${gitea_pod}" -- \
      wget -q -O - \
      --header="Authorization: token ${gitea_token}" \
      "http://localhost:3000/api/v1/repos/${repo_owner}/${repo_name}/hooks" 2>/dev/null || echo "[]")

    local old_hook_ids
    old_hook_ids=$(echo "$existing_hooks" | python3 -c "
import sys, json
try:
    hooks = json.load(sys.stdin)
    for h in hooks:
        if '/api/webhook' in h.get('config',{}).get('url',''):
            print(h['id'])
except:
    pass" 2>/dev/null)

    for hid in $old_hook_ids; do
        kubectl exec -n "${GITEA_NAMESPACE}" "${gitea_pod}" -- \
          wget -q -O /dev/null \
          --header="Authorization: token ${gitea_token}" \
          --post-data="_method=DELETE" \
          "http://localhost:3000/api/v1/repos/${repo_owner}/${repo_name}/hooks/${hid}" 2>/dev/null || true
        echo "  Removed stale webhook (id=${hid})."
    done

    kubectl exec -n "${GITEA_NAMESPACE}" "${gitea_pod}" -- \
      wget -q -O /dev/null \
      --header="Authorization: token ${gitea_token}" \
      --header="Content-Type: application/json" \
      --post-data="{\"type\":\"gitea\",\"config\":{\"url\":\"${argocd_svc_url}\",\"content_type\":\"json\",\"secret\":\"${webhook_secret}\"},\"events\":[\"push\"],\"active\":true}" \
      "http://localhost:3000/api/v1/repos/${repo_owner}/${repo_name}/hooks" 2>/dev/null
    echo "  Gitea webhook created -> ${argocd_svc_url}"
}

# Verify webhook CA bundle is correctly patched on all Validating/Mutating
# webhook configurations owned by Kubernaut. After an interrupted helm install
# the CA bundle may be empty, causing all CR validation to fail with TLS errors.
# See: kubernaut-demo-scenarios#3 sub-issue 3.1
_verify_webhook_ca_bundle() {
    local ca_data
    ca_data=$(kubectl get configmap authwebhook-ca -n "${PLATFORM_NS}" \
      -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
    if [ -z "$ca_data" ]; then
        echo "  WARNING: authwebhook-ca ConfigMap not found or empty; skipping CA bundle check."
        return 0
    fi

    local ca_b64
    ca_b64=$(printf '%s' "$ca_data" | base64 | tr -d '\n')

    for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
        local configs
        configs=$(kubectl get "$kind" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i authwebhook || true)
        for cfg in $configs; do
            local count
            count=$(kubectl get "$kind" "$cfg" -o json 2>/dev/null | \
              python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('webhooks',[])))" 2>/dev/null || echo "0")
            for idx in $(seq 0 $((count - 1))); do
                local existing
                existing=$(kubectl get "$kind" "$cfg" -o jsonpath="{.webhooks[${idx}].clientConfig.caBundle}" 2>/dev/null || true)
                if [ -z "$existing" ]; then
                    echo "  Patching empty caBundle on ${kind}/${cfg} webhook[${idx}]..."
                    kubectl patch "$kind" "$cfg" --type='json' \
                      -p "[{\"op\":\"replace\",\"path\":\"/webhooks/${idx}/clientConfig/caBundle\",\"value\":\"${ca_b64}\"}]" 2>/dev/null || true
                fi
            done
        done
    done
    echo "  Webhook CA bundles verified."
}

# On OCP, ensure the Alertmanager ServiceAccount can POST signals to the Gateway.
# The chart creates the ClusterRole but not the OCP-specific ClusterRoleBinding.
# See: kubernaut-demo-scenarios#3 sub-issue 3.2
_ensure_alertmanager_rbac() {
    if [ "$PLATFORM" != "ocp" ]; then
        return 0
    fi
    if kubectl get clusterrolebinding alertmanager-ocp-gateway-signal-source &>/dev/null; then
        echo "  Alertmanager ClusterRoleBinding already exists."
        return 0
    fi
    if ! kubectl get clusterrole gateway-signal-source &>/dev/null; then
        echo "  WARNING: gateway-signal-source ClusterRole not found; chart may not be installed yet."
        return 0
    fi
    kubectl create clusterrolebinding alertmanager-ocp-gateway-signal-source \
      --clusterrole=gateway-signal-source \
      --serviceaccount=openshift-monitoring:alertmanager-main \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "  Created Alertmanager -> Gateway RBAC binding (OCP)."
}

# Create gitea-repo-creds secret for workflow dependency validation.
# See: kubernaut-demo-scenarios#3 sub-issue 3.5
_ensure_gitea_repo_creds() {
    local ns="kubernaut-workflows"
    if ! kubectl get namespace "$ns" &>/dev/null; then
        echo "  WARNING: ${ns} namespace does not exist yet; skipping gitea-repo-creds."
        return 0
    fi
    kubectl create secret generic gitea-repo-creds \
      -n "$ns" \
      --from-literal=username="${GITEA_ADMIN_USER}" \
      --from-literal=password="${GITEA_ADMIN_PASS}" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "  gitea-repo-creds secret ensured in ${ns}."
}

# ── AAP credential preflight ──────────────────────────────────────────────
# The WE controller creates ephemeral K8s credentials using the built-in AAP
# type 17 (kind:kubernetes) which has NO env injectors.  kubernetes.core
# modules need K8S_AUTH_HOST / K8S_AUTH_API_KEY env vars, which only a custom
# credential type with env injectors provides.  The ephemeral creds are
# passed in the job launch payload alongside any template-attached creds,
# so as long as the template also has a type-33 (env-injected) credential
# attached, the env vars are available and the playbook works.
#
# This function ensures the entire AAP credential chain is correct and then
# runs a smoke-test job to prove it end-to-end.  It fails hard on any error.

_aap_connect() {
    local aap_ns="${AAP_NAMESPACE:-aap}"
    _AAP_SVC=$(kubectl get svc -n "$aap_ns" -o name 2>/dev/null \
        | grep -m1 'controller-service' | sed 's|^service/||' || true)
    [ -z "$_AAP_SVC" ] && { echo "  ERROR: no AAP controller-service found in ${aap_ns}."; return 1; }

    _AAP_PASS=$(kubectl get secret "${_AAP_SVC%-service}-admin-password" -n "$aap_ns" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    [ -z "$_AAP_PASS" ] && { echo "  ERROR: cannot retrieve AAP admin password."; return 1; }

    _AAP_PF_PORT=18053
    kubectl port-forward -n "$aap_ns" "svc/${_AAP_SVC}" "${_AAP_PF_PORT}:80" &>/dev/null &
    _AAP_PF_PID=$!
    sleep 3

    _AAP_AUTH="admin:${_AAP_PASS}"
    _AAP_URL="http://localhost:${_AAP_PF_PORT}"

    if ! curl -sf "${_AAP_URL}/api/v2/ping/" -u "$_AAP_AUTH" >/dev/null 2>&1; then
        echo "  ERROR: AAP API not reachable at ${_AAP_URL}."
        kill "$_AAP_PF_PID" 2>/dev/null; wait "$_AAP_PF_PID" 2>/dev/null || true
        return 1
    fi
}

_aap_disconnect() {
    [ -n "${_AAP_PF_PID:-}" ] && kill "$_AAP_PF_PID" 2>/dev/null && wait "$_AAP_PF_PID" 2>/dev/null || true
    _AAP_PF_PID=""
}

_preflight_aap_credentials() {
    echo "  Connecting to AAP API..."
    _aap_connect || return 1

    local org_id
    org_id=$(curl -sf "${_AAP_URL}/api/v2/organizations/?name=Kubernaut+Demo" -u "$_AAP_AUTH" | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d['results'][0]['id'] if d.get('results') else '')" 2>/dev/null || echo "")
    [ -z "$org_id" ] && org_id=1

    # ── 1. Ensure custom credential type with K8S_AUTH env injectors ────────
    local ct_id
    ct_id=$(curl -sf "${_AAP_URL}/api/v2/credential_types/?search=env+injected" -u "$_AAP_AUTH" | \
        python3 -c "
import json, sys
for ct in json.load(sys.stdin).get('results', []):
    if 'K8S_AUTH_HOST' in ct.get('injectors', {}).get('env', {}):
        print(ct['id']); sys.exit(0)
" 2>/dev/null || echo "")

    if [ -z "$ct_id" ]; then
        echo "  Creating custom K8s credential type with env injectors..."
        ct_id=$(curl -sf -X POST "${_AAP_URL}/api/v2/credential_types/" -u "$_AAP_AUTH" \
            -H 'Content-Type: application/json' \
            -d "$(jq -n '{
                name:"Kubernetes API Token (env injected)",
                description:"Injects K8S_AUTH env vars for kubernetes.core",
                kind:"cloud",
                inputs:{fields:[{id:"host",type:"string",label:"API Host"},{id:"bearer_token",type:"string",label:"Bearer Token",secret:true},{id:"verify_ssl",type:"boolean",label:"Verify SSL"}],required:["host","bearer_token"]},
                injectors:{env:{K8S_AUTH_HOST:"{{host}}",K8S_AUTH_API_KEY:"{{bearer_token}}",K8S_AUTH_VERIFY_SSL:"{{verify_ssl}}"}}
            }')" | \
            python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    fi
    if [ -z "$ct_id" ]; then
        echo "  ERROR: Failed to find or create K8s env-injected credential type."
        _aap_disconnect; return 1
    fi
    echo "  K8s credential type: ${ct_id} (env-injected)"

    # ── 2. Create / refresh K8s credential with a fresh SA token ────────────
    local sa_name="migrate-postgres-emptydir-to-pvc-gitops-v1-runner"
    local sa_ns="kubernaut-workflows"
    local sa_token
    sa_token=$(kubectl create token "$sa_name" -n "${sa_ns}" --duration=24h 2>/dev/null || echo "")
    if [ -z "$sa_token" ]; then
        echo "  ERROR: Could not create token for SA ${sa_name} in ${sa_ns}."
        _aap_disconnect; return 1
    fi

    local k8s_cred_id
    k8s_cred_id=$(curl -sf "${_AAP_URL}/api/v2/credentials/?name=kubernaut-k8s-reader" -u "$_AAP_AUTH" | \
        python3 -c "import json,sys; r=json.load(sys.stdin).get('results',[]); print(r[0]['id'] if r else '')" 2>/dev/null || echo "")

    local _k8s_body
    _k8s_body=$(jq -n --argjson org "$org_id" --argjson ct "$ct_id" --arg token "$sa_token" \
        '{name:"kubernaut-k8s-reader",description:"In-cluster K8s access (env-injected)",organization:$org,credential_type:$ct,inputs:{host:"https://kubernetes.default.svc",bearer_token:$token,verify_ssl:false}}')
    if [ -n "$k8s_cred_id" ]; then
        curl -sf -X PATCH "${_AAP_URL}/api/v2/credentials/${k8s_cred_id}/" -u "$_AAP_AUTH" \
            -H 'Content-Type: application/json' -d "$_k8s_body" >/dev/null
        echo "  K8s credential refreshed (id=${k8s_cred_id}, type=${ct_id})"
    else
        k8s_cred_id=$(curl -sf -X POST "${_AAP_URL}/api/v2/credentials/" -u "$_AAP_AUTH" \
            -H 'Content-Type: application/json' -d "$_k8s_body" | \
            python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
        echo "  K8s credential created (id=${k8s_cred_id}, type=${ct_id})"
    fi
    if [ -z "$k8s_cred_id" ]; then
        echo "  ERROR: Failed to create K8s credential."
        _aap_disconnect; return 1
    fi

    # ── 3. Ensure Gitea credential type + credential ───────────────────────
    local gitea_ct_id
    gitea_ct_id=$(curl -sf "${_AAP_URL}/api/v2/credential_types/?name=kubernaut-secret-gitea-repo-creds" -u "$_AAP_AUTH" | \
        python3 -c "import json,sys; r=json.load(sys.stdin).get('results',[]); print(r[0]['id'] if r else '')" 2>/dev/null || echo "")
    if [ -z "$gitea_ct_id" ]; then
        gitea_ct_id=$(curl -sf -X POST "${_AAP_URL}/api/v2/credential_types/" -u "$_AAP_AUTH" \
            -H 'Content-Type: application/json' \
            -d "$(jq -n '{name:"kubernaut-secret-gitea-repo-creds",description:"Gitea repo credentials",kind:"cloud",
                inputs:{fields:[{id:"username",type:"string",label:"Username"},{id:"password",type:"string",label:"Password",secret:true}],required:["username","password"]},
                injectors:{extra_vars:{GITEA_USER:"{{username}}",GITEA_PASS:"{{password}}"}}}')" | \
            python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    fi

    local gitea_cred_id
    gitea_cred_id=$(curl -sf "${_AAP_URL}/api/v2/credentials/?name=kubernaut-gitea-creds" -u "$_AAP_AUTH" | \
        python3 -c "import json,sys; r=json.load(sys.stdin).get('results',[]); print(r[0]['id'] if r else '')" 2>/dev/null || echo "")
    if [ -z "$gitea_cred_id" ] && [ -n "$gitea_ct_id" ]; then
        local _gitea_body
        _gitea_body=$(jq -n --argjson org "$org_id" --argjson ct "$gitea_ct_id" \
            --arg user "${GITEA_ADMIN_USER:-kubernaut}" --arg pass "${GITEA_ADMIN_PASS:-kubernaut123}" \
            '{name:"kubernaut-gitea-creds",description:"Gitea credentials for GitOps playbooks",organization:$org,credential_type:$ct,inputs:{username:$user,password:$pass}}')
        gitea_cred_id=$(curl -sf -X POST "${_AAP_URL}/api/v2/credentials/" -u "$_AAP_AUTH" \
            -H 'Content-Type: application/json' -d "$_gitea_body" | \
            python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
        echo "  Gitea credential created (id=${gitea_cred_id})"
    else
        echo "  Gitea credential exists (id=${gitea_cred_id})"
    fi

    # ── 4. Attach both credentials to the migrate job template ──────────────
    local tmpl_ids
    tmpl_ids=$(curl -sf "${_AAP_URL}/api/v2/job_templates/" -u "$_AAP_AUTH" | python3 -c "
import json, sys
for t in json.load(sys.stdin).get('results', []):
    if 'migrate' in t.get('name','').lower():
        print(t['id'])
" 2>/dev/null || true)

    if [ -z "$tmpl_ids" ]; then
        echo "  ERROR: No 'migrate' job template found in AAP."
        _aap_disconnect; return 1
    fi

    for tid in $tmpl_ids; do
        curl -sf -X POST "${_AAP_URL}/api/v2/job_templates/${tid}/credentials/" -u "$_AAP_AUTH" \
            -H 'Content-Type: application/json' -d "{\"id\":${k8s_cred_id}}" >/dev/null 2>&1 || true
        [ -n "$gitea_cred_id" ] && \
            curl -sf -X POST "${_AAP_URL}/api/v2/job_templates/${tid}/credentials/" -u "$_AAP_AUTH" \
                -H 'Content-Type: application/json' -d "{\"id\":${gitea_cred_id}}" >/dev/null 2>&1 || true
        echo "  Credentials attached to template ${tid}"
    done

    # ── 5. Smoke-test: launch the template with --check and verify K8s auth ─
    echo "  Running AAP smoke-test (launching template with K8s credential)..."
    local _smoke_tmpl
    _smoke_tmpl=$(echo "$tmpl_ids" | head -1)
    local _smoke_job_id
    _smoke_job_id=$(curl -sf -X POST "${_AAP_URL}/api/v2/job_templates/${_smoke_tmpl}/launch/" \
        -u "$_AAP_AUTH" \
        -H 'Content-Type: application/json' \
        -d "{\"extra_vars\":{\"NODE_NAME\":\"smoke-test\",\"PVC_SIZE\":\"1Gi\",\"RR_NAME\":\"smoke\",\"RR_NAMESPACE\":\"${PLATFORM_NS}\",\"TARGET_RESOURCE_KIND\":\"Deployment\",\"TARGET_RESOURCE_NAME\":\"smoke\",\"TARGET_RESOURCE_NAMESPACE\":\"default\",\"WFE_NAME\":\"smoke\",\"WFE_NAMESPACE\":\"${PLATFORM_NS}\"}}" | \
        python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

    if [ -z "$_smoke_job_id" ]; then
        echo "  ERROR: Failed to launch AAP smoke-test job."
        _aap_disconnect; return 1
    fi
    echo "  Smoke-test job launched (id=${_smoke_job_id}), waiting..."

    local _deadline=$(($(date +%s) + 90))
    local _status=""
    while [ "$(date +%s)" -lt "$_deadline" ]; do
        _status=$(curl -sf "${_AAP_URL}/api/v2/jobs/${_smoke_job_id}/" -u "$_AAP_AUTH" | \
            python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
        case "$_status" in
            successful) break ;;
            failed|error|canceled)
                local _stdout
                _stdout=$(curl -sf "${_AAP_URL}/api/v2/jobs/${_smoke_job_id}/stdout/?format=txt" \
                    -u "$_AAP_AUTH" 2>&1 || echo "")
                if echo "$_stdout" | grep -qi "Invalid kube-config\|Could not create API client\|Authentication.*failed\|Unauthorized"; then
                    echo "  ERROR: AAP smoke-test job ${_smoke_job_id} ${_status} — K8s auth broken."
                    echo "  ── Job stdout ──"
                    echo "$_stdout" | head -40 | sed 's/^/    /'
                    echo "  ─────────────────"
                    echo ""
                    echo "  The K8s credential chain is broken. The Ansible playbook cannot"
                    echo "  authenticate to the cluster. Verify that:"
                    echo "    1. Credential type ${ct_id} has K8S_AUTH_HOST/K8S_AUTH_API_KEY injectors"
                    echo "    2. Credential ${k8s_cred_id} uses type ${ct_id} (not built-in type 17)"
                    echo "    3. The SA token for ${sa_name} is valid"
                    _aap_disconnect; return 1
                fi
                echo "  Smoke-test job ${_status} but K8s auth is working (failure is playbook logic with dummy inputs)."
                break
                ;;
        esac
        sleep 5
    done

    case "$_status" in
        successful)
            echo "  Smoke-test passed (job ${_smoke_job_id} successful)."
            ;;
        failed)
            # Already handled in the loop — auth works, playbook logic failed with dummy inputs.
            ;;
        running|pending|waiting)
            local _task_count
            _task_count=$(curl -sf "${_AAP_URL}/api/v2/jobs/${_smoke_job_id}/job_events/?event=runner_on_ok&page_size=1" \
                -u "$_AAP_AUTH" | python3 -c "import json,sys; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
            if [ "$_task_count" -gt 0 ]; then
                echo "  Smoke-test still running but K8s auth verified (${_task_count} tasks OK). Cancelling..."
                curl -sf -X POST "${_AAP_URL}/api/v2/jobs/${_smoke_job_id}/cancel/" \
                    -u "$_AAP_AUTH" >/dev/null 2>&1 || true
            else
                echo "  ERROR: AAP smoke-test timed out without completing any K8s task."
                _aap_disconnect; return 1
            fi
            ;;
        *)
            echo "  ERROR: AAP smoke-test ended in unexpected status: ${_status}"
            _aap_disconnect; return 1
            ;;
    esac

    _aap_disconnect
    echo "  AAP credential preflight complete."
}

_check_prerequisites() {
    local missing=false
    if ! kubectl get secret llm-credentials -n "${PLATFORM_NS}" &>/dev/null; then
        echo "  WARNING: llm-credentials secret not found in ${PLATFORM_NS}."
        echo "    Create it before running the scenario:"
        echo "      kubectl create secret generic llm-credentials -n ${PLATFORM_NS} \\"
        echo "        --from-literal=OPENAI_API_KEY=sk-..."
        missing=true
    fi
    if ! kubectl get secret slack-webhook -n "${PLATFORM_NS}" &>/dev/null; then
        echo "  NOTE: slack-webhook secret not found in ${PLATFORM_NS} (notifications will use console only)."
    fi

    if ! _preflight_aap_credentials; then
        echo ""
        echo "  ERROR: AAP credential preflight failed. Cannot proceed."
        exit 1
    fi

    if [ "$missing" = true ]; then
        echo ""
        echo "  ERROR: Required prerequisites are missing. Fix the above before running."
        exit 1
    fi
}

run_setup() {
echo "============================================="
echo " DiskPressure emptyDir Migration Demo (#324)"
echo " emptyDir growth -> PredictedDiskPressure"
echo " (proactive, BR-SP-106) -> Ansible/AWX"
echo " -> GitOps PVC migration -> DB restore"
echo ""
echo " Rate auto-tuned to node filesystem capacity"
echo "============================================="
echo ""

echo "==> Checking prerequisites..."
_check_prerequisites

# Enable KA Prometheus toolset for this scenario (kubernaut#473, #108).
# Also ensures cluster-monitoring-view RBAC on OCP (kubernaut#574).
echo "==> Enabling Kubernaut Agent Prometheus toolset for this scenario..."
enable_prometheus_toolset
echo ""

# Reduce EA timing for webhook-based ArgoCD sync.
# With a Gitea→ArgoCD webhook, sync is near-instant; the default 3m gitOpsSyncDelay
# and 5m proactiveAlertDelay add unnecessary wait. cleanup.sh restores defaults.
echo "==> Tuning RO timing for webhook-based GitOps (gitOpsSyncDelay=30s, stabilization=3m, alertDelay=3m)..."
kubectl get configmap remediationorchestrator-config -n "${PLATFORM_NS}" -o yaml \
  | sed 's/gitOpsSyncDelay: "3m"/gitOpsSyncDelay: "30s"/' \
  | sed 's/gitOpsSyncDelay: "1m"/gitOpsSyncDelay: "30s"/' \
  | sed 's/stabilizationWindow: "5m"/stabilizationWindow: "3m"/' \
  | sed 's/proactiveAlertDelay: "5m"/proactiveAlertDelay: "3m"/' \
  | kubectl apply -f - >/dev/null 2>&1
kubectl rollout restart deploy/remediationorchestrator-controller -n "${PLATFORM_NS}" >/dev/null 2>&1
kubectl rollout status deploy/remediationorchestrator-controller -n "${PLATFORM_NS}" --timeout=120s >/dev/null 2>&1
echo ""

# Step 0: Ensure a worker node has the scenario label.
# On Kind, kind-config-diskpressure.yaml bakes the label at cluster creation.
# On OCP, we pick the first schedulable worker and label it.
# NOTE: the NoSchedule taint is applied AFTER the constrained FS setup (Step 0c)
# so that oc debug pods can still schedule on the node during setup.
_ensure_scenario_node() {
    if kubectl get nodes -l scenario=disk-pressure -o name 2>/dev/null | grep -q .; then
        echo "  Node with scenario=disk-pressure already exists."
        return 0
    fi
    local target
    target=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' \
      --field-selector=spec.unschedulable!=true \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$target" ]; then
        echo "  WARNING: no schedulable worker node found; pods may stay Pending."
        return 0
    fi
    echo "  Labeling node ${target} for disk-pressure scenario..."
    kubectl label node "$target" scenario=disk-pressure --overwrite
}
echo "==> Step 0: Ensuring a worker node is labeled for this scenario..."
_ensure_scenario_node

# Mount a constrained loop filesystem on the worker node's kubelet data dir
# so nodefs.available reports against a small (fixed-size) filesystem. This
# makes the scenario deterministic regardless of the host/node disk size.
CONSTRAINED_FS_SIZE_MB="${CONSTRAINED_FS_SIZE_MB:-10240}"
CONSTRAINED_FS_MOUNTED=false
_setup_constrained_nodefs() {
    local node_name
    node_name=$(kubectl get nodes -l scenario=disk-pressure \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$node_name" ]; then
        echo "  WARNING: no disk-pressure node found; skipping constrained FS."
        return 0
    fi

    # Build the shell command to run on the host.
    local host_cmds
    host_cmds="
        if mount | grep -q '/var/lib/kubelet.*loop'; then
            echo 'ALREADY_MOUNTED'
            exit 0
        fi
        systemctl stop kubelet
        cp -a /var/lib/kubelet /tmp/kubelet-backup
        truncate -s ${CONSTRAINED_FS_SIZE_MB}M /tmp/nodefs-constrained.img
        mkfs.ext4 -F /tmp/nodefs-constrained.img >/dev/null 2>&1
        mount -o loop /tmp/nodefs-constrained.img /var/lib/kubelet
        cp -a /tmp/kubelet-backup/. /var/lib/kubelet/ 2>/dev/null || true
        rm -rf /tmp/kubelet-backup
        systemctl start kubelet
    "

    if [ "${PLATFORM:-kind}" = "ocp" ]; then
        local already
        already=$(oc debug "node/${node_name}" -- chroot /host bash -c \
          "mount | grep '/var/lib/kubelet.*loop'" 2>/dev/null || true)
        if [ -n "$already" ]; then
            echo "  Constrained filesystem already mounted on ${node_name}."
            CONSTRAINED_FS_MOUNTED=true
            return 0
        fi
        echo "  Creating ${CONSTRAINED_FS_SIZE_MB}MB constrained filesystem on ${node_name} (via oc debug)..."
        oc debug "node/${node_name}" -- nsenter --mount --pid --target 1 bash -c "$host_cmds"
    else
        local container_runtime="podman"
        if ! command -v podman &>/dev/null; then
            container_runtime="docker"
        fi
        local already
        already=$("${container_runtime}" exec "${node_name}" \
          mount 2>/dev/null | grep '/var/lib/kubelet.*loop' || true)
        if [ -n "$already" ]; then
            echo "  Constrained filesystem already mounted on ${node_name}."
            CONSTRAINED_FS_MOUNTED=true
            return 0
        fi
        echo "  Creating ${CONSTRAINED_FS_SIZE_MB}MB constrained filesystem on ${node_name}..."
        "${container_runtime}" exec "${node_name}" bash -c "$host_cmds"
    fi

    echo "  Waiting for node ${node_name} to become Ready..."
    local ready=false
    for i in $(seq 1 60); do
        local node_status
        node_status=$(kubectl get node "${node_name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [ "$node_status" = "True" ]; then
            ready=true
            break
        fi
        sleep 2
    done
    if [ "$ready" = "true" ]; then
        echo "  Node ${node_name} is Ready with ${CONSTRAINED_FS_SIZE_MB}MB constrained filesystem."
        CONSTRAINED_FS_MOUNTED=true
    else
        echo "  WARNING: Node ${node_name} not Ready after 120s. Continuing anyway."
        CONSTRAINED_FS_MOUNTED=true
    fi
}
echo "==> Step 0b: Setting up constrained filesystem on worker node..."
_setup_constrained_nodefs

# Step 0c: Apply the NoSchedule taint AFTER constrained FS is ready.
# This must happen after Step 0b because oc debug pods need to schedule
# on the node to set up the loop mount.
echo "==> Step 0c: Applying NoSchedule taint to scenario node..."
_scenario_node=$(kubectl get nodes -l scenario=disk-pressure \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$_scenario_node" ]; then
    kubectl taint node "$_scenario_node" scenario=disk-pressure:NoSchedule --overwrite 2>/dev/null || true
    echo "  Tainted ${_scenario_node} with scenario=disk-pressure:NoSchedule"
fi
echo ""

# Step 1: Push deployment YAML to Gitea repo
echo "==> Step 1: Pushing deployment manifests to Gitea..."
WORK_DIR=$(mktemp -d)
kill_stale_gitea_pf
kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http "${GITEA_LOCAL_PORT}:3000" &
PF_PID=$!
wait_for_port "${GITEA_LOCAL_PORT}" 45

curl -s -X POST "http://localhost:${GITEA_LOCAL_PORT}/api/v1/user/repos" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${REPO_NAME}\", \"auto_init\": true}" -o /dev/null 2>/dev/null || true

cd "${WORK_DIR}"
git clone "http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@localhost:${GITEA_LOCAL_PORT}/${GITEA_ADMIN_USER}/${REPO_NAME}.git" repo 2>/dev/null
cd repo
git config user.email "kubernaut@kubernaut.ai"
git config user.name "Kubernaut Setup"

mkdir -p disk-pressure-emptydir

cat > disk-pressure-emptydir/deployment.yaml <<MANIFEST
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-emptydir
  namespace: demo-diskpressure
  labels:
    app: postgres-emptydir
    kubernaut.ai/managed: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres-emptydir
  template:
    metadata:
      labels:
        app: postgres-emptydir
    spec:
      nodeSelector:
        scenario: disk-pressure
      tolerations:
      - key: scenario
        value: disk-pressure
        effect: NoSchedule
      - key: node.kubernetes.io/disk-pressure
        operator: Exists
        effect: NoSchedule
      containers:
      - name: postgres
        image: ${PG_IMAGE}
        ports:
        - containerPort: 5432
        env:
        - name: ${PG_ENV_USER}
          value: "postgres"
        - name: ${PG_ENV_DB}
          value: "postgres"
        - name: ${PG_ENV_PASS}
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: password
        - name: PGDATA
          value: "${PG_DATA_VALUE}"
        resources:
          requests:
            memory: "512Mi"
            cpu: "100m"
          limits:
            memory: "2Gi"
            cpu: "500m"
        volumeMounts:
        - name: data
          mountPath: ${PG_DATA_MOUNT}
        - name: init-sql
          mountPath: /docker-entrypoint-initdb.d
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "postgres"]
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: data
        emptyDir:
          sizeLimit: 8Gi
      - name: init-sql
        configMap:
          name: postgres-init-sql
MANIFEST

cat > disk-pressure-emptydir/secret.yaml <<'MANIFEST'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: demo-diskpressure
type: Opaque
stringData:
  password: "kubernaut-demo-pass"
MANIFEST

cat > disk-pressure-emptydir/service.yaml <<'MANIFEST'
apiVersion: v1
kind: Service
metadata:
  name: postgres-emptydir
  namespace: demo-diskpressure
spec:
  selector:
    app: postgres-emptydir
  ports:
  - port: 5432
    targetPort: 5432
MANIFEST

cat > disk-pressure-emptydir/configmap.yaml <<'MANIFEST'
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init-sql
  namespace: demo-diskpressure
data:
  init.sql: |
    CREATE TABLE IF NOT EXISTS events (
        id         SERIAL PRIMARY KEY,
        timestamp  TIMESTAMPTZ NOT NULL DEFAULT now(),
        source     TEXT NOT NULL DEFAULT 'sensor',
        payload    TEXT NOT NULL
    );
    CREATE OR REPLACE PROCEDURE simulate_data_growth(
        batch_size  INT DEFAULT 500,
        num_iters   INT DEFAULT 200,
        sleep_ms    INT DEFAULT 100
    )
    LANGUAGE plpgsql AS $$
    DECLARE
        i INT;
    BEGIN
        FOR i IN 1..num_iters LOOP
            INSERT INTO events (source, payload)
            SELECT
                'sensor-' || (random()*100)::int,
                repeat(md5(random()::text), 32)
            FROM generate_series(1, batch_size);
            COMMIT;
            PERFORM pg_sleep(sleep_ms / 1000.0);
        END LOOP;
    END;
    $$;
MANIFEST

cat > disk-pressure-emptydir/kustomization.yaml <<'MANIFEST'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - secret.yaml
  - service.yaml
  - configmap.yaml
MANIFEST

git add .
if git diff --cached --quiet 2>/dev/null; then
    echo "  Gitea repo already has deployment manifests."
else
    git commit -m "feat: initial postgres-emptydir deployment (emptyDir volume)"
    git push origin main
    echo "  Deployment manifests pushed to Gitea."
fi

kill "${PF_PID}" 2>/dev/null || true
cd /
rm -rf "${WORK_DIR}"

# Step 1b: Ensure gitea-repo-creds secret exists for workflow dependency validation
echo "==> Step 1b: Ensuring gitea-repo-creds secret..."
_ensure_gitea_repo_creds

# Step 1c: Register the postgres-specific emptyDir-to-PVC workflow.
_WF_YAML="${SCRIPT_DIR}/../../deploy/remediation-workflows/disk-pressure-emptydir/disk-pressure-emptydir.yaml"
if [ -f "$_WF_YAML" ]; then
    _WF_NAME=$(awk '/kind: RemediationWorkflow/{found=1} found && /^  name:/{print $2; exit}' "$_WF_YAML")
    if ! kubectl get remediationworkflow "$_WF_NAME" -n "${PLATFORM_NS}" &>/dev/null; then
        echo "==> Step 1c: Registering workflow ${_WF_NAME}..."
        kubectl apply -f "$_WF_YAML" 2>&1 | sed 's/^/  /'
    else
        echo "==> Step 1c: Workflow ${_WF_NAME} already registered."
    fi
fi

# Step 2: Apply all manifests (namespace, Prometheus rule, ArgoCD Application)
echo "==> Step 2: Applying manifests (namespace, Prometheus rule, ArgoCD Application)..."

echo "  Verifying webhook CA bundles..."
_verify_webhook_ca_bundle

echo "  Ensuring Alertmanager RBAC..."
_ensure_alertmanager_rbac

MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")

kubectl apply --server-side --force-conflicts -k "${MANIFEST_DIR}"

# Patch PrometheusRule with correct instance and mountpoint for the target
# environment. The static manifest uses Kind defaults (instance=~"stress-worker.*",
# mountpoint="/") which don't match OCP nodes or the constrained loop FS.
_SCENARIO_NODE=$(kubectl get nodes -l scenario=disk-pressure \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ "${PLATFORM:-kind}" = "ocp" ]; then
    _INSTANCE_RE="${_SCENARIO_NODE}"
else
    _NODE_IP=$(kubectl get node "$_SCENARIO_NODE" \
      -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    _INSTANCE_RE="${_NODE_IP}:.*"
fi
if [ "$CONSTRAINED_FS_MOUNTED" = "true" ]; then
    _MOUNTPOINT="/var/lib/kubelet"
elif [ "${PLATFORM:-kind}" = "ocp" ]; then
    _MOUNTPOINT="/var"
else
    _MOUNTPOINT="/"
fi
_EXPR="max by (mountpoint, instance) (predict_linear(node_filesystem_avail_bytes{mountpoint=\"${_MOUNTPOINT}\", instance=~\"${_INSTANCE_RE}\"}[1m], 1800)) < 0"
if [ "${PLATFORM:-kind}" = "ocp" ]; then
    _PROM_NS="openshift-monitoring"
else
    _PROM_NS="${NAMESPACE}"
fi
echo "  Patching PrometheusRule: mountpoint=${_MOUNTPOINT}, instance=~${_INSTANCE_RE}, node=${_SCENARIO_NODE}"
kubectl get prometheusrule demo-diskpressure-rules -n "${_PROM_NS}" -o json \
  | python3 -c "
import json, sys
node_name = '''${_SCENARIO_NODE}'''
rule = json.load(sys.stdin)
for g in rule['spec']['groups']:
    for r in g['rules']:
        if r.get('alert') == 'PredictedDiskPressure':
            r['expr'] = '''${_EXPR}'''
            r['labels']['node'] = node_name
            r['annotations']['node_name'] = node_name
            r['annotations']['summary'] = f'Node {node_name} predicted to exhaust disk within 30 minutes'
json.dump(rule, sys.stdout)
" | kubectl apply -f - 2>/dev/null
echo "  PrometheusRule patched."

# Speed up ArgoCD polling for demo
ARGOCD_NS=$(get_argocd_namespace)
kubectl patch configmap argocd-cm -n "${ARGOCD_NS}" --type merge \
  -p '{"data":{"timeout.reconciliation":"60s"}}' 2>/dev/null || true

# Step 2b: Configure Gitea -> ArgoCD webhook for instant sync on push.
# The remediation playbook pushes a PVC migration commit; without this
# webhook ArgoCD would poll with up to 3 min delay.
echo "==> Step 2b: Ensuring Gitea webhook notifies ArgoCD on push..."
setup_gitea_argocd_webhook "${GITEA_ADMIN_USER}" "${REPO_NAME}"

# Step 3: Wait for ArgoCD sync and PostgreSQL readiness
echo "==> Step 3: Waiting for ArgoCD sync..."
for i in $(seq 1 60); do
    if kubectl get deployment postgres-emptydir -n "${NAMESPACE}" &>/dev/null; then
        echo "  ArgoCD synced deployment (attempt ${i})."
        break
    fi
    sleep 5
done

echo "==> Step 4: Waiting for PostgreSQL pod readiness..."
kubectl rollout status deployment/postgres-emptydir -n "${NAMESPACE}" --timeout=180s
kubectl wait --for=condition=Available deployment/postgres-emptydir \
  -n "${NAMESPACE}" --timeout=180s
echo "  PostgreSQL is running with emptyDir storage."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 5: Run init SQL explicitly.
# The standard Docker image auto-runs /docker-entrypoint-initdb.d/*.sql, but the
# Red Hat sclorg image does not. Run it via psql for both platforms.
echo "==> Step 5: Running init SQL..."
local init_pod
init_pod=$(kubectl get pods -n "${NAMESPACE}" -l app=postgres-emptydir \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "${NAMESPACE}" "${init_pod}" -- \
  psql -U postgres -d postgres -f /docker-entrypoint-initdb.d/init.sql 2>&1 | sed 's/^/    /'
echo "  simulate_data_growth() procedure is available."
echo ""
}

_label_target_node() {
    local pod node
    pod=$(kubectl get pods -n "${NAMESPACE}" -l app=postgres-emptydir \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    node=$(kubectl get pod "$pod" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    if [ -z "$node" ]; then
        echo "WARNING: could not determine target node for PredictedDiskPressure signal"
        return 0
    fi
    echo "==> Labeling node ${node} for Kubernaut signal acceptance..."
    kubectl label node "$node" \
        kubernaut.ai/managed=true \
        kubernaut.ai/environment=production \
        kubernaut.ai/business-unit=infrastructure \
        kubernaut.ai/service-owner=platform-team \
        kubernaut.ai/criticality=high \
        kubernaut.ai/sla-tier=tier-1 \
        --overwrite
}

_unlabel_target_node() {
    local node
    for node in $(kubectl get nodes -l kubernaut.ai/managed=true \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
        kubectl label node "$node" \
            kubernaut.ai/managed- \
            kubernaut.ai/environment- \
            kubernaut.ai/business-unit- \
            kubernaut.ai/service-owner- \
            kubernaut.ai/criticality- \
            kubernaut.ai/sla-tier- 2>/dev/null || true
    done
}

run_inject() {
# Label the node running the postgres pod so the Gateway accepts the proactive signal
_label_target_node

POD=$(kubectl get pods -n "${NAMESPACE}" -l app=postgres-emptydir \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
    echo "ERROR: No postgres-emptydir pod found in ${NAMESPACE}"
    exit 1
fi

NODE=$(kubectl get pod "$POD" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}')
echo "==> Target node: ${NODE}"

# ── Dynamic rate calculation based on node filesystem capacity ──────────
# Get disk stats directly from the postgres pod (on the target node).
#
# PrometheusRule: predict_linear(v[1m], 1800) < 0 for 15s
#   W=60s (window), H=1800s (horizon), F=15s (for clause)
#   Desired margin = 1200s (20 min -- enough for LLM investigation + workflow)
#
# Strategy: fill fast enough for predict_linear to fire within ~75s
# (W + F) but slow enough to leave ~6 min margin for the Ansible playbook.
# R = usable / (W + F + margin) gives alert at ~75s with safe margin.
#
# We prefer Case A (faster) and fall back to Case B.

DF_LINE=$(kubectl exec -n "${NAMESPACE}" "${POD}" -- df -B1 "${PG_DATA_MOUNT}" 2>/dev/null | tail -1)
TOTAL_BYTES=$(echo "$DF_LINE" | awk '{print $2}')
AVAIL_BYTES=$(echo "$DF_LINE" | awk '{print $4}')

if [ -z "$TOTAL_BYTES" ] || [ -z "$AVAIL_BYTES" ]; then
    echo "ERROR: Could not read filesystem stats from pod ${POD}"
    exit 1
fi

AVAIL_MB=$(( AVAIL_BYTES / 1048576 ))
TOTAL_MB=$(( TOTAL_BYTES / 1048576 ))
THRESHOLD_MB=$(( TOTAL_MB * 15 / 100 ))  # kubelet default: 15%
USABLE_MB=$(( AVAIL_MB - THRESHOLD_MB ))

MIN_USABLE_MB="${MIN_USABLE_MB:-50}"
if [ "$USABLE_MB" -lt "$MIN_USABLE_MB" ]; then
    echo "ERROR: Only ${USABLE_MB} MB usable on ${NODE} (need >= ${MIN_USABLE_MB} MB). Free disk first."
    exit 1
fi

# W=60, H=1800, F=15, margin=1200  (all in seconds)
# H=1800 matches predict_linear horizon in PrometheusRule (30 min lookahead)
# margin=1200 gives ~20 min for LLM investigation + workflow execution
# PostgreSQL disk amplification: ~2x (tuple headers, WAL, TOAST)
PG_AMP=2

RATE_MB_S=$(awk "BEGIN {
    avail=${AVAIL_MB}; usable=${USABLE_MB}
    W=60; H=1800; F=15; margin=1200

    r = usable / (W + F + margin)
    r_min = avail / (W + H)
    if (r < r_min) r = r_min
    if (r < 2) r = 2
    if (r > 15) r = 15
    printf \"%.1f\", r
}")

SLEEP_MS=50
BATCH_SIZE=$(awk "BEGIN { v=int(${RATE_MB_S}*${SLEEP_MS}/1000*1024/${PG_AMP}); if(v<10)v=10; print v }")
ITERATIONS=$(awk "BEGIN { print int(${USABLE_MB}*1024/${BATCH_SIZE})+1000 }")

# Estimate timing (minutes)
EST_ALERT_MIN=$(awk "BEGIN {
    r=${RATE_MB_S}*60; W=1; H=30; F=0.25
    t_window = W + F
    t_slope = ${AVAIL_MB}/r - H + F
    t = (t_slope > t_window) ? t_slope : t_window
    printf \"%.1f\", t
}")
EST_EVICT_MIN=$(awk "BEGIN { printf \"%.0f\", ${USABLE_MB}/(${RATE_MB_S}*60) }")

echo "==> Injecting fault: dynamic postgres data growth to fill emptyDir..."
echo "  Node:       ${NODE}"
echo "  Disk:       ${TOTAL_MB} MB total, ${AVAIL_MB} MB available"
echo "  Threshold:  ${THRESHOLD_MB} MB (15%), usable: ${USABLE_MB} MB"
echo "  Rate:       ${RATE_MB_S} MB/s (batch=${BATCH_SIZE} rows, sleep=${SLEEP_MS}ms)"
echo "  Iterations: ${ITERATIONS}"
echo "  Estimate:   PredictedDiskPressure at ~${EST_ALERT_MIN} min, eviction at ~${EST_EVICT_MIN} min"
echo ""
echo "  Starting postgres continuous data growth..."
kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  psql -U postgres -d postgres -c "CALL simulate_data_growth(${BATCH_SIZE}, ${ITERATIONS}, ${SLEEP_MS});" &

echo ""
echo "  Data growth running in background. Waiting for PredictedDiskPressure..."
echo "  Monitor: kubectl get nodes -o custom-columns='NAME:.metadata.name,DISK_PRESSURE:.status.conditions[?(@.type==\"DiskPressure\")].status'"
echo ""
}

run_monitor() {
echo "==> Pipeline in progress..."
echo ""
echo "  Expected flow (proactive, BR-SP-106):"
echo "    1. PredictedDiskPressure alert fires (predict_linear, before kubelet eviction)"
echo "    2. SP classifies as proactive, normalizes signal to DiskPressure"
echo "    3. KA uses proactive prompt (predict & prevent, not RCA)"
echo "    4. AI detects emptyDir antipattern + ArgoCD management"
echo "    5. AI selects MigrateEmptyDirToPVC workflow"
echo "    6. RAR created -- human approval required"
echo "    7. AWX dispatches Ansible playbook (engine=ansible)"
echo "    8. Playbook: cordon -> pg_dump -> git commit (PVC + remove nodeSelector) -> ArgoCD sync -> pg_restore -> uncordon"
echo "    9. EA verifies DiskPressure never materialized + DB accessible"
echo ""

if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
}

case "$SUBCOMMAND" in
  setup)  run_setup ;;
  inject) run_inject ;;
  all)    run_setup; run_inject; run_monitor ;;
  *)      echo "Usage: $0 [setup|inject|all]"; exit 1 ;;
esac
