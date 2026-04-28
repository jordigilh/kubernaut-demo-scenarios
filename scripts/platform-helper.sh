#!/usr/bin/env bash
# Shared platform deployment helpers for demo scenarios.
# Source this from run.sh:
#   source "$(dirname "$0")/../../scripts/platform-helper.sh"

# Force line-buffered stdout/stderr when not running in a TTY (e.g. over SSH).
# Without this, output is 4KB-block-buffered and remote monitoring sees stale data.
# Guard variable prevents infinite re-exec since this file is source'd.
if [ -z "${_KUBERNAUT_LINEBUF:-}" ] && [ ! -t 1 ] && command -v stdbuf &>/dev/null; then
    export _KUBERNAUT_LINEBUF=1
    exec stdbuf -oL -eL "$0" "$@"
fi

# macOS does not ship GNU coreutils `timeout`. Provide a portable fallback
# using perl (available on macOS and all RHEL/Fedora systems).
if ! command -v timeout &>/dev/null; then
    timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
fi

PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBERNAUT_REPO="${KUBERNAUT_REPO:-$(cd "${REPO_ROOT}/../kubernaut" 2>/dev/null && pwd || true)}"
KUBERNAUT_OCI_CHART="oci://quay.io/kubernaut-ai/charts/kubernaut"
if [ -n "${CHART_VERSION:-}" ]; then
    # --chart-version requires OCI registry; Helm ignores --version for local paths (#269)
    CHART_REF="${KUBERNAUT_OCI_CHART}"
    CHART_SOURCE="oci"
elif [ -n "${KUBERNAUT_REPO}" ] && [ -d "${KUBERNAUT_REPO}/charts/kubernaut" ]; then
    CHART_REF="${KUBERNAUT_REPO}/charts/kubernaut"
    CHART_SOURCE="local"
else
    CHART_REF="${KUBERNAUT_OCI_CHART}"
    CHART_SOURCE="oci"
fi
KIND_VALUES="${REPO_ROOT}/helm/kubernaut-kind-values.yaml"
OCP_VALUES="${REPO_ROOT}/helm/kubernaut-ocp-values.yaml"
SDK_CONFIG="${HOME}/.kubernaut/sdk-config.yaml"

# KUBECONFIG is managed by kind-helper.sh (for Kind clusters) or by the
# user's environment (for OCP / BYO clusters). We do NOT override it here
# to avoid masking an OCP context with a stale Kind kubeconfig (#44).

# ── Platform detection ───────────────────────────────────────────────────────
# Detects whether the target cluster is OpenShift (ocp) or vanilla Kubernetes (kind).
# Override with PLATFORM=ocp or PLATFORM=kind before sourcing this file.
detect_platform() {
    local api_output
    api_output=$(kubectl api-resources --api-group=config.openshift.io 2>/dev/null) || true
    if echo "$api_output" | grep -q ClusterVersion; then
        echo "ocp"
    else
        echo "kind"
    fi
}

PLATFORM="${PLATFORM:-$(detect_platform)}"
export PLATFORM

# ── Gitea port allocation ────────────────────────────────────────────────────
# Platform-aware local port for Gitea port-forward. Different defaults for Kind
# and OCP avoid conflicts when both clusters share the same host (e.g., helios08).
if [ -z "${GITEA_LOCAL_PORT:-}" ]; then
    if [ "$PLATFORM" = "ocp" ]; then
        GITEA_LOCAL_PORT=3032
    else
        GITEA_LOCAL_PORT=3031
    fi
fi
export GITEA_LOCAL_PORT

# Kill any orphaned Gitea port-forward on $GITEA_LOCAL_PORT from a previous
# script run that failed before cleanup.
kill_stale_gitea_pf() {
    local pids
    pids=$(pgrep -f "port-forward.*svc/gitea-http.*${GITEA_LOCAL_PORT}:3000" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo "  Killing stale Gitea port-forward on port ${GITEA_LOCAL_PORT} (PIDs: ${pids})"
        kill $pids 2>/dev/null || true
        sleep 1
    fi
}

wait_for_port() {
    local port="${1:?port required}" timeout="${2:-15}"
    local elapsed=0
    until curl -sf "http://localhost:${port}" >/dev/null 2>&1; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "  WARNING: port ${port} not ready after ${timeout}s"
            return 1
        fi
    done
}

# Returns the kustomize directory to use for kubectl apply -k.
# Uses the OCP overlay when available and PLATFORM=ocp, otherwise the base manifests.
get_manifest_dir() {
    local scenario_dir="$1"
    if [ "$PLATFORM" = "ocp" ] && [ -d "${scenario_dir}/overlays/ocp" ]; then
        echo "${scenario_dir}/overlays/ocp"
    else
        echo "${scenario_dir}/manifests"
    fi
}

# Returns the namespace where ArgoCD is installed.
# OCP uses the OpenShift GitOps operator (openshift-gitops);
# Kind uses the community ArgoCD install in the "argocd" namespace.
get_argocd_namespace() {
    if [ "$PLATFORM" = "ocp" ]; then
        echo "openshift-gitops"
    else
        echo "argocd"
    fi
}

# Returns the ArgoCD server service name for the current platform.
# OCP (OpenShift GitOps operator): openshift-gitops-server
# Kind (community ArgoCD):         argocd-server
get_argocd_server_svc() {
    if [ "$PLATFORM" = "ocp" ]; then
        echo "openshift-gitops-server"
    else
        echo "argocd-server"
    fi
}

# Restart AlertManager to clear stale notification state after cleanup.
# On OCP the AlertManager is managed by the cluster monitoring operator;
# restarting it is unnecessary (alerts auto-resolve) and may be disruptive.
restart_alertmanager() {
    if [ "$PLATFORM" = "ocp" ]; then
        echo "  (OCP: skipping AlertManager restart -- alerts auto-resolve)"
        return 0
    fi
    echo "==> Restarting AlertManager to clear stale notification state..."
    kubectl rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager -n monitoring
    kubectl rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager -n monitoring --timeout=60s
}

# Delete all pipeline CRDs (RR, SP, AIA, WFE, EA, RAR, Notif) from kubernaut-system.
# Call this from cleanup.sh after deleting the scenario namespace so that stale
# resources from previous runs don't interfere with subsequent scenarios.
purge_pipeline_crds() {
    local ns="${PLATFORM_NS:-kubernaut-system}"
    echo "==> Purging pipeline CRDs from ${ns}..."
    kubectl delete remediationrequests --all -n "$ns" --ignore-not-found 2>/dev/null || true
    kubectl delete signalprocessings --all -n "$ns" --ignore-not-found 2>/dev/null || true
    kubectl delete aianalyses --all -n "$ns" --ignore-not-found 2>/dev/null || true
    kubectl delete workflowexecutions --all -n "$ns" --ignore-not-found 2>/dev/null || true
    kubectl delete effectivenessassessments --all -n "$ns" --ignore-not-found 2>/dev/null || true
    kubectl delete remediationapprovalrequests --all -n "$ns" --ignore-not-found 2>/dev/null || true
    kubectl delete notificationrequests --all -n "$ns" --ignore-not-found 2>/dev/null || true
}

# Silence a specific alert in AlertManager (platform-aware).
silence_alert() {
    local alert_name="$1"
    local namespace="$2"
    local duration="${3:-2m}"
    if [ "$PLATFORM" = "ocp" ]; then
        echo "  (OCP: skipping alert silence -- alerts auto-resolve)"
        return 0
    fi
    kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -- \
      amtool silence add "alertname=${alert_name}" "namespace=${namespace}" \
      --alertmanager.url=http://localhost:9093 "--duration=${duration}" \
      --comment="Cleanup silence" 2>/dev/null || true
}

# Apply a multi-document workflow YAML, routing each document to the
# correct namespace. RemediationWorkflow docs get -n $ns (platform namespace),
# other docs (ServiceAccount, ClusterRole, ClusterRoleBinding) are applied
# without -n so they respect their own metadata.namespace.
_apply_workflow_yaml() {
    local yaml_file="$1" ns="$2"
    local tmpdir _rc=0
    tmpdir=$(mktemp -d)
    trap "rm -rf '${tmpdir}'" RETURN

    kubectl create namespace "${WE_NAMESPACE:-kubernaut-workflows}" \
        --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - 2>/dev/null || true

    python3 -c "
import sys, os
d, n, f = sys.argv[1], 0, None
for line in open(sys.argv[2]):
    if line.strip() == '---':
        n += 1; f = None; continue
    if f is None: f = open(os.path.join(d, f'doc-{n}.yaml'), 'a')
    f.write(line)
" "$tmpdir" "$yaml_file"

    for doc in "$tmpdir"/doc-*.yaml; do
        [ -f "$doc" ] || continue
        if grep -q 'kind: RemediationWorkflow' "$doc"; then
            kubectl apply -n "$ns" -f "$doc" 2>&1 || _rc=$?
        else
            kubectl apply -f "$doc" 2>&1 || _rc=$?
        fi
    done
    return $_rc
}

# Ensure all ActionType and RemediationWorkflow CRDs are applied.
# Idempotent: kubectl apply is a no-op when resources are unchanged.
seed_action_types_and_workflows() {
    local at_dir="${REPO_ROOT}/deploy/action-types"
    local ns="${PLATFORM_NS:-kubernaut-system}"

    if [ -d "$at_dir" ] && ls "$at_dir"/*.yaml &>/dev/null; then
        echo "==> Seeding ActionType CRDs..."
        kubectl apply -f "$at_dir/" 2>&1 | grep -v unchanged | sed 's/^/    /' || true
    fi

    local wf_dir="${REPO_ROOT}/deploy/remediation-workflows"
    if [ -d "$wf_dir" ]; then
        echo "==> Seeding RemediationWorkflow CRDs (namespace: ${ns})..."
        local applied=0 skipped=0 failed=0
        while IFS= read -r -d '' yaml_file; do
            local basename="${yaml_file##*/}"

            # Skip Ansible-engine workflows when AWX/AAP is not installed
            if grep -q 'engine: ansible' "$yaml_file"; then
                if ! kubectl get deployment -A -l app.kubernetes.io/managed-by=awx-operator --no-headers 2>/dev/null | grep -q . && \
                   ! kubectl get automationcontroller -A --no-headers 2>/dev/null | grep -q .; then
                    echo "    SKIP ${basename} (engine: ansible — no AWX/AAP found)"
                    skipped=$((skipped + 1))
                    continue
                fi
            fi

            # Check secret dependencies declared in the workflow.
            # WE jobs run in kubernaut-workflows, so check both the platform
            # namespace and the workflow execution namespace (DD-WE-006).
            local we_ns="${WE_NAMESPACE:-kubernaut-workflows}"
            local unmet=""
            while IFS= read -r secret_name; do
                [ -z "$secret_name" ] && continue
                if ! kubectl get secret "$secret_name" -n "${ns}" &>/dev/null && \
                   ! kubectl get secret "$secret_name" -n "${we_ns}" &>/dev/null; then
                    unmet="${secret_name}"
                    break
                fi
            done < <(awk '/^[[:space:]]*secrets:/{f=1; next} f && /- name:/{print $NF} f && !/^[[:space:]]*-/{f=0}' "$yaml_file" 2>/dev/null)

            if [ -n "$unmet" ]; then
                echo "    SKIP ${basename} (secret \"${unmet}\" not found in ${ns} or ${we_ns})"
                skipped=$((skipped + 1))
                continue
            fi

            local _output
            if _output=$(_apply_workflow_yaml "$yaml_file" "$ns" 2>&1); then
                echo "$_output" | grep -v unchanged | sed 's/^/    /' || true
                applied=$((applied + 1))
            else
                echo "$_output" | grep -v unchanged | sed 's/^/    /' || true
                echo "    WARN: ${basename} was not fully applied (webhook rejection or validation error)"
                failed=$((failed + 1))
            fi
        done < <(find "$wf_dir" -name '*.yaml' -print0)
        echo "    Applied ${applied} workflow(s), skipped ${skipped}, failed ${failed}."
    fi
}

# Validate that the demo environment is ready (no installs).
# Checks: kubeconfig, Kubernaut Helm release, all deployments ready, monitoring stack.
# After validation, seeds all ActionType and RemediationWorkflow CRDs.
# Exits with a clear error if anything is missing.
require_demo_ready() {
    local fail=false

    if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot connect to Kubernetes cluster."
        echo "  Kubeconfig: ${KUBECONFIG}"
        if [ "$PLATFORM" = "ocp" ]; then
            echo "  Check: oc whoami --show-server"
        else
            echo "  Is the Kind cluster running? Check: kind get clusters"
        fi
        fail=true
    fi

    if [ "$fail" = false ] && ! helm status kubernaut -n "${PLATFORM_NS}" &>/dev/null \
       && ! kubectl get kubernaut -n "${PLATFORM_NS}" &>/dev/null; then
        echo "ERROR: Kubernaut platform is not installed in ${PLATFORM_NS}."
        echo ""
        echo "Ensure the OCP cluster is configured with user-workload monitoring enabled."
        fail=true
    fi

    if [ "$fail" = false ]; then
        local not_ready
        not_ready=$(kubectl get deployments -n "${PLATFORM_NS}" -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyReplicas}/{.spec.replicas}{"\n"}{end}' 2>/dev/null \
            | awk -F'[=/]' '$2 != $3 || $2 == ""' | head -5)
        if [ -n "$not_ready" ]; then
            echo "WARNING: Some Kubernaut deployments are not ready:"
            echo "$not_ready" | sed 's/^/    /'
        fi
    fi

    if [ "$fail" = false ]; then
        if [ "$PLATFORM" = "ocp" ]; then
            if ! kubectl get namespace openshift-monitoring &>/dev/null; then
                echo "ERROR: openshift-monitoring namespace not found."
                fail=true
            fi
        else
            if ! helm status kube-prometheus-stack -n monitoring &>/dev/null; then
                echo "ERROR: Monitoring stack is not installed."
                fail=true
            fi
        fi
    fi

    if [ "$fail" = true ]; then
        echo ""
        if [ "$PLATFORM" = "ocp" ]; then
            echo "Ensure the OCP cluster is configured with user-workload monitoring enabled."
        else
            echo "Run setup first:  bash scripts/setup-demo-cluster.sh"
        fi
        exit 1
    fi

    if [ "$PLATFORM" = "ocp" ]; then
        _warn_slow_ksm_scrape
    fi

    seed_action_types_and_workflows
}

# Detect the kube-state-metrics scrape interval on OCP and warn if it
# exceeds 30s.  A slow scrape interval delays metric propagation after
# remediation, causing the EffectivenessMonitor to sample stale data.
# See kubernaut-demo-scenarios#293.
_warn_slow_ksm_scrape() {
    local interval
    interval=$(kubectl get servicemonitor kube-state-metrics -n openshift-monitoring \
        -o jsonpath='{.spec.endpoints[0].interval}' 2>/dev/null || true)
    if [ -z "$interval" ]; then
        return 0
    fi
    local seconds
    seconds=$(echo "$interval" | sed 's/s$//' | sed 's/m$//' )
    if echo "$interval" | grep -q 'm$'; then
        seconds=$((seconds * 60))
    fi
    if [ "$seconds" -gt 30 ]; then
        echo "  NOTE: OCP kube-state-metrics scrape interval is ${interval} (>${seconds}s)."
        echo "  The OCP values file sets stabilizationWindow: 120s to compensate (#293)."
    fi
}

wait_platform_ready() {
    local ns="${PLATFORM_NS:-kubernaut-system}"
    local timeout="${1:-300}"
    local deployments
    deployments=$(kubectl get deployments -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [ -z "$deployments" ]; then
        return 0
    fi

    echo "==> Waiting for all deployments in ${ns} to be ready (timeout ${timeout}s)..."
    local failed=0
    for dep in $deployments; do
        if ! kubectl rollout status deployment/"$dep" -n "$ns" --timeout="${timeout}s" 2>&1 | sed 's/^/    /'; then
            echo "  WARNING: deployment/${dep} did not become ready within ${timeout}s"
            failed=1
        fi
    done
    if [ "$failed" -eq 0 ]; then
        echo "  All deployments in ${ns} are ready."
    else
        echo "  WARNING: Some deployments in ${ns} are not ready."
    fi
    return $failed
}

ensure_platform() {
    _ensure_pre_install_secrets

    if helm status kubernaut -n "${PLATFORM_NS}" &>/dev/null; then
        echo "  Kubernaut platform already installed."
        _check_llm_credentials
        return 0
    fi

    echo "==> Installing Kubernaut platform..."

    local version_flag=""
    if [ -n "${CHART_VERSION:-}" ]; then
        version_flag="--version ${CHART_VERSION}"
    fi

    echo "  Applying CRDs (source: ${CHART_SOURCE})..."
    if [ "${CHART_SOURCE}" = "local" ]; then
        kubectl apply -f "${CHART_REF}/crds/" 2>&1 | sed 's/^/    /'
    else
        local _crd_tmp
        _crd_tmp=$(mktemp -d)
        helm pull "${CHART_REF}" ${version_flag} --untar --untardir "${_crd_tmp}" 2>&1 | sed 's/^/    /'
        kubectl apply -f "${_crd_tmp}/kubernaut/crds/" 2>&1 | sed 's/^/    /'
        rm -rf "${_crd_tmp}"
    fi

    local llm_flags=""
    if [ -f "${SDK_CONFIG}" ]; then
        llm_flags="--set-file kubernautAgent.sdkConfigContent=${SDK_CONFIG}"
        echo "  SDK config loaded from ${SDK_CONFIG}"
    elif [ -n "${KUBERNAUT_LLM_PROVIDER:-}" ] && [ -n "${KUBERNAUT_LLM_MODEL:-}" ]; then
        llm_flags="--set kubernautAgent.llm.provider=${KUBERNAUT_LLM_PROVIDER} --set kubernautAgent.llm.model=${KUBERNAUT_LLM_MODEL}"
        echo "  LLM quickstart: provider=${KUBERNAUT_LLM_PROVIDER} model=${KUBERNAUT_LLM_MODEL}"
    else
        echo "  WARNING: No LLM config found."
        echo "  Either create an SDK config file:"
        echo "    cp helm/sdk-config.yaml.example ~/.kubernaut/sdk-config.yaml"
        echo "  Or set environment variables for the quickstart path:"
        echo "    export KUBERNAUT_LLM_PROVIDER=anthropic"
        echo "    export KUBERNAUT_LLM_MODEL=claude-sonnet-4-20250514"
    fi

    local values_file
    if [ "$PLATFORM" = "ocp" ]; then
        values_file="${OCP_VALUES}"
    else
        values_file="${KIND_VALUES}"
    fi

    if [ -n "${CHART_VERSION:-}" ]; then
        echo "  Installing Helm chart (${CHART_SOURCE}: ${CHART_REF}, version: ${CHART_VERSION}, platform: ${PLATFORM})..."
    else
        echo "  Installing Helm chart (${CHART_SOURCE}: ${CHART_REF}, platform: ${PLATFORM})..."
    fi
    local policy_flags=""
    local sp_policy="${REPO_ROOT}/deploy/defaults/signalprocessing-policy.rego"
    local aa_policy="${REPO_ROOT}/deploy/defaults/approval-policy.rego"
    if [ -f "$sp_policy" ]; then
        policy_flags="--set-file signalprocessing.policies.content=${sp_policy}"
    fi
    if [ -f "$aa_policy" ]; then
        policy_flags="${policy_flags} --set-file aianalysis.policies.content=${aa_policy}"
    fi

    # Do NOT use --wait: the chart has a post-install migration hook that must
    # run before datastorage becomes ready. --wait blocks until all pods are
    # ready, creating a deadlock (datastorage needs migration → migration is
    # post-install → post-install waits for --wait → --wait waits for datastorage).
    # Instead, let Helm finish (hooks run), then poll via wait_platform_ready().
    helm upgrade --install kubernaut "${CHART_REF}" \
        --namespace "${PLATFORM_NS}" \
        --create-namespace \
        --values "${values_file}" \
        ${llm_flags} \
        ${version_flag} \
        ${policy_flags} \
        --skip-crds \
        --timeout 10m

    echo "  Kubernaut platform installed in ${PLATFORM_NS}."
    wait_platform_ready
    seed_action_types_and_workflows
    _check_llm_credentials
}

# Seed the RemediationWorkflow CRD for a specific scenario.
# The DataStorage controller reconciles it into the workflow catalog.
# Args: $1=scenario directory name (e.g., "crashloop")
seed_scenario_workflow() {
    local scenario="$1"
    local schema_file="${REPO_ROOT}/deploy/remediation-workflows/${scenario}/${scenario}.yaml"

    if [ ! -f "$schema_file" ]; then
        echo "WARNING: No deploy/remediation-workflows/${scenario}/${scenario}.yaml, skipping."
        return 0
    fi

    echo "==> Applying RemediationWorkflow CRD for scenario: ${scenario}"
    kubectl apply -f "$schema_file" -n "${PLATFORM_NS}" 2>&1 | sed 's/^/    /'
    echo "  Workflow applied for ${scenario}."
}

# Create secrets that must exist before Helm install (#243):
#   - postgresql-secret (PostgreSQL + DataStorage credentials)
#   - valkey-secret     (Valkey/Redis credentials)
#   - llm-credentials   (VertexAI ADC for kubernaut-agent)
#   - slack-webhook     (notification credential store, issue #104)
# Also labels the namespace for Helm adoption if it was pre-created.
#
# Recommended on v1.1.0-rc13 (prevents credential drift when helm
# rollback regenerates secrets with different passwords).
# Required on v1.1.0-rc14+ (kubernaut#557) where the chart no longer
# auto-generates database credentials.
_ensure_pre_install_secrets() {
    if ! command -v openssl &>/dev/null; then
        echo "ERROR: openssl is required to generate database passwords."
        echo "  Install it (e.g. 'brew install openssl' or 'apt install openssl') and retry."
        return 1
    fi

    kubectl create namespace "${PLATFORM_NS}" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

    # Helm namespace adoption labels
    kubectl label namespace "${PLATFORM_NS}" app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null
    kubectl annotate namespace "${PLATFORM_NS}" \
        meta.helm.sh/release-name=kubernaut \
        meta.helm.sh/release-namespace="${PLATFORM_NS}" --overwrite 2>/dev/null

    # PostgreSQL + DataStorage consolidated secret (#243).
    # Reuse existing password on upgrades to avoid the rotation bug (kubernaut#557).
    local pg_pass=""
    if kubectl get secret postgresql-secret -n "${PLATFORM_NS}" &>/dev/null; then
        pg_pass=$(kubectl get secret postgresql-secret -n "${PLATFORM_NS}" \
            -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d 2>/dev/null) || true
    fi
    if [ -z "$pg_pass" ]; then
        pg_pass=$(openssl rand -base64 24)
    fi
    kubectl create secret generic postgresql-secret \
        -n "${PLATFORM_NS}" \
        --from-literal=POSTGRES_USER=slm_user \
        --from-literal=POSTGRES_PASSWORD="${pg_pass}" \
        --from-literal=POSTGRES_DB=action_history \
        --from-literal=db-secrets.yaml="$(printf 'username: "slm_user"\npassword: "%s"' "${pg_pass}")" \
        --dry-run=client -o yaml | kubectl apply -f - 2>&1 | sed 's/^/    /'

    # Valkey secret (#243).
    # VALKEY_PASSWORD is a plain-text key for safe extraction on upgrades;
    # valkey-secrets.yaml is the YAML file mounted by DataStorage.
    local valkey_pass=""
    if kubectl get secret valkey-secret -n "${PLATFORM_NS}" &>/dev/null; then
        valkey_pass=$(kubectl get secret valkey-secret -n "${PLATFORM_NS}" \
            -o jsonpath='{.data.VALKEY_PASSWORD}' | base64 -d 2>/dev/null) || true
    fi
    if [ -z "$valkey_pass" ]; then
        valkey_pass=$(openssl rand -base64 24)
    fi
    kubectl create secret generic valkey-secret \
        -n "${PLATFORM_NS}" \
        --from-literal=VALKEY_PASSWORD="${valkey_pass}" \
        --from-literal=valkey-secrets.yaml="$(printf 'password: "%s"' "${valkey_pass}")" \
        --dry-run=client -o yaml | kubectl apply -f - 2>&1 | sed 's/^/    /'

    # LLM credentials (VertexAI ADC)
    local adc_file="${HOME}/.config/gcloud/application_default_credentials.json"
    if [ -f "${adc_file}" ] && [ -f "${SDK_CONFIG}" ]; then
        local project region
        project=$(grep -E 'gcp_project_id|vertex_project' "${SDK_CONFIG}" | head -1 | awk -F'"' '{print $2}') || true
        region=$(grep -E 'gcp_region|vertex_location' "${SDK_CONFIG}" | head -1 | awk -F'"' '{print $2}') || true
        if [ -n "${project}" ] && [ -n "${region}" ]; then
            kubectl create secret generic llm-credentials \
                -n "${PLATFORM_NS}" \
                --from-literal=VERTEXAI_PROJECT="${project}" \
                --from-literal=VERTEXAI_LOCATION="${region}" \
                --from-literal=GOOGLE_APPLICATION_CREDENTIALS="/etc/kubernaut-agent/credentials/application_default_credentials.json" \
                --from-file=application_default_credentials.json="${adc_file}" \
                --dry-run=client -o yaml | kubectl apply -f - 2>&1 | sed 's/^/    /'
        fi
    fi

    # Slack webhook (issue #104: named credential store)
    local slack_file="${HOME}/.kubernaut/notification/slack-webhook.url"
    if [ -f "${slack_file}" ]; then
        local webhook_url
        webhook_url=$(cat "${slack_file}")
        kubectl create secret generic slack-webhook \
            -n "${PLATFORM_NS}" \
            --from-literal=webhook-url="${webhook_url}" \
            --dry-run=client -o yaml | kubectl apply -f - 2>&1 | sed 's/^/    /'
    fi
}

_check_llm_credentials() {
    if ! kubectl get secret llm-credentials -n "${PLATFORM_NS}" &>/dev/null; then
        echo ""
        echo "  WARNING: LLM credentials not configured."
        echo "  AI analysis will not work until you create the llm-credentials Secret."
        echo ""
        echo "  Quick setup (Vertex AI):"
        echo "    cp credentials/vertex-ai-example.yaml my-llm-credentials.yaml"
        echo "    # Edit with your provider credentials"
        echo "    kubectl apply -f my-llm-credentials.yaml"
        echo "    kubectl rollout restart deployment/kubernaut-agent -n ${PLATFORM_NS}"
        echo ""
    fi
}

# ── Prometheus toolset management ────────────────────────────────────────────
# Enable/disable the Prometheus toolset in the Kubernaut Agent SDK config.
#
# Strategy: update the local ~/.kubernaut/sdk-config.yaml file first, then
# re-apply the full ConfigMap content with Helm ownership annotations so that
# subsequent `helm upgrade` commands don't hit field-manager conflicts (#229).
# Falls back to direct ConfigMap patch if no local SDK config file exists.

_sdk_configmap_name() {
    kubectl get configmap -n "${PLATFORM_NS}" -o name 2>/dev/null \
      | grep -o 'kubernaut-agent-sdk-config[^ ]*' | head -1 || true
}

_prom_url_for_platform() {
    if [ "${PLATFORM:-kind}" = "ocp" ]; then
        echo "https://prometheus-k8s.openshift-monitoring.svc:9091"
    else
        echo "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
    fi
}

_update_sdk_config_toolset() {
    local file="$1" enabled="$2" prom_url="$3"
    local content
    content=$(cat "$file")

    if echo "$content" | grep -q 'prometheus/metrics:' 2>/dev/null; then
        if [ "$enabled" = "true" ]; then
            content=$(echo "$content" | sed '/prometheus\/metrics:/{n;s/enabled: false/enabled: true/;}')
        else
            content=$(echo "$content" | sed '/prometheus\/metrics:/{n;s/enabled: true/enabled: false/;}')
        fi
        content=$(echo "$content" | sed "s|prometheus_url:.*|prometheus_url: \"${prom_url}\"|")
    elif [ "$enabled" = "true" ]; then
        content="${content}
toolsets:
  prometheus/metrics:
    enabled: true
    config:
      prometheus_url: \"${prom_url}\""
    fi

    printf '%s\n' "$content" > "$file"
}

_apply_sdk_config_to_cluster() {
    local file="$1"
    local cm_name
    cm_name=$(_sdk_configmap_name)
    if [ -z "$cm_name" ]; then
        echo "  WARNING: Kubernaut Agent SDK ConfigMap not found in cluster."
        return 1
    fi

    local content
    content=$(cat "$file")

    local cluster_content
    cluster_content=$(kubectl get "configmap/${cm_name}" -n "${PLATFORM_NS}" \
      -o jsonpath='{.data.sdk-config\.yaml}' 2>/dev/null || true)

    if [ "$content" = "$cluster_content" ]; then
        return 0
    fi

    kubectl create configmap "${cm_name}" -n "${PLATFORM_NS}" \
        --from-literal="sdk-config.yaml=${content}" \
        --dry-run=client -o yaml \
      | kubectl annotate -f - --local --overwrite \
          meta.helm.sh/release-name=kubernaut \
          meta.helm.sh/release-namespace="${PLATFORM_NS}" -o yaml \
      | kubectl label -f - --local --overwrite \
          app.kubernetes.io/managed-by=Helm -o yaml \
      | kubectl apply --server-side --force-conflicts -f - >/dev/null 2>&1

    kubectl rollout restart deployment/kubernaut-agent -n "${PLATFORM_NS}" >/dev/null 2>&1
    kubectl rollout status deployment/kubernaut-agent -n "${PLATFORM_NS}" --timeout=120s >/dev/null 2>&1
}

enable_prometheus_toolset() {
    local prom_url
    prom_url=$(_prom_url_for_platform)

    # On OCP, KA's SA needs cluster-monitoring-view to query prometheus-k8s.
    # The chart creates "kubernaut-agent-monitoring-view" when both
    # kubernautAgent.prometheus.enabled and ocpMonitoringRbac are true.
    if [ "${PLATFORM:-}" = "ocp" ]; then
        if ! kubectl get clusterrolebinding kubernaut-agent-monitoring-view &>/dev/null; then
            local ka_sa
            ka_sa=$(kubectl get sa -n "${PLATFORM_NS}" -l app=kubernaut-agent \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "kubernaut-agent-sa")
            kubectl create clusterrolebinding kubernaut-agent-monitoring-view \
                --clusterrole=cluster-monitoring-view \
                --serviceaccount="${PLATFORM_NS}:${ka_sa}" 2>/dev/null || true
            echo "  Prometheus RBAC: granted cluster-monitoring-view to ${ka_sa}."
        fi

        # The chart's kubernaut-alertmanager-view ClusterRole uses nonResourceURLs,
        # but OCP's kube-rbac-proxy requires resource-level access on
        # monitoring.coreos.com/alertmanagers/api (kubernaut#576).
        # Patch the existing role to add the missing permission.
        if kubectl get clusterrole kubernaut-alertmanager-view &>/dev/null; then
            local has_resource_rule
            has_resource_rule=$(kubectl get clusterrole kubernaut-alertmanager-view \
                -o jsonpath='{.rules[?(@.apiGroups)].resources}' 2>/dev/null || true)
            if ! echo "$has_resource_rule" | grep -q 'alertmanagers/api'; then
                kubectl get clusterrole kubernaut-alertmanager-view -o json \
                  | python3 -c "
import json, sys
role = json.load(sys.stdin)
role['rules'].append({
    'apiGroups': ['monitoring.coreos.com'],
    'resources': ['alertmanagers/api'],
    'verbs': ['get']
})
json.dump(role, sys.stdout)
" | kubectl apply -f - >/dev/null 2>&1
                echo "  AlertManager RBAC: patched kubernaut-alertmanager-view with monitoring.coreos.com/alertmanagers/api."
            fi
        fi
    fi

    if [ -f "${SDK_CONFIG}" ]; then
        local before_hash after_hash
        before_hash=$(shasum "${SDK_CONFIG}" 2>/dev/null | awk '{print $1}' || echo "")
        _update_sdk_config_toolset "${SDK_CONFIG}" "true" "$prom_url"
        after_hash=$(shasum "${SDK_CONFIG}" 2>/dev/null | awk '{print $1}' || echo "")

        if [ "$before_hash" = "$after_hash" ]; then
            echo "  Prometheus toolset already enabled."
            return 0
        fi

        _apply_sdk_config_to_cluster "${SDK_CONFIG}"
        echo "  Prometheus toolset enabled (local SDK config + cluster ConfigMap)."
    else
        local cm_name
        cm_name=$(_sdk_configmap_name)
        if [ -z "$cm_name" ]; then
            echo "  WARNING: Kubernaut Agent SDK ConfigMap not found; cannot enable Prometheus toolset."
            echo "  Enable manually in ~/.kubernaut/sdk-config.yaml under toolsets.prometheus/metrics."
            return 0
        fi

        local current
        current=$(kubectl get "configmap/${cm_name}" -n "${PLATFORM_NS}" \
          -o jsonpath='{.data.sdk-config\.yaml}' 2>/dev/null || true)

        local needs_patch=false
        if echo "$current" | grep -q 'prometheus/metrics:' 2>/dev/null; then
            if ! echo "$current" | grep -A1 'prometheus/metrics:' | grep -q 'enabled: true'; then
                current=$(echo "$current" | sed '/prometheus\/metrics:/{n;s/enabled: false/enabled: true/;}')
                needs_patch=true
            fi
            if ! echo "$current" | grep -qF "prometheus_url: \"${prom_url}\"" 2>/dev/null && \
               ! echo "$current" | grep -qF "prometheus_url: '${prom_url}'" 2>/dev/null && \
               ! echo "$current" | grep -qF "prometheus_url: ${prom_url}" 2>/dev/null; then
                current=$(echo "$current" | sed "s|prometheus_url:.*|prometheus_url: \"${prom_url}\"|")
                needs_patch=true
            fi
        else
            current="${current}
toolsets:
  prometheus/metrics:
    enabled: true
    config:
      prometheus_url: \"${prom_url}\""
            needs_patch=true
        fi

        if [ "$needs_patch" = false ]; then
            echo "  Prometheus toolset already enabled."
            return 0
        fi

        kubectl patch "configmap/${cm_name}" -n "${PLATFORM_NS}" --type merge \
          -p "{\"data\":{\"sdk-config.yaml\":$(echo "$current" | jq -Rs .)}}" >/dev/null 2>&1
        kubectl rollout restart deployment/kubernaut-agent -n "${PLATFORM_NS}" >/dev/null 2>&1
        kubectl rollout status deployment/kubernaut-agent -n "${PLATFORM_NS}" --timeout=120s >/dev/null 2>&1
        echo "  Prometheus toolset enabled via SDK ConfigMap (no local file)."
    fi
}

disable_prometheus_toolset() {
    local prom_url
    prom_url=$(_prom_url_for_platform)

    if [ -f "${SDK_CONFIG}" ]; then
        _update_sdk_config_toolset "${SDK_CONFIG}" "false" "$prom_url"
        _apply_sdk_config_to_cluster "${SDK_CONFIG}"
        echo "  Prometheus toolset disabled (local SDK config + cluster ConfigMap)."
    else
        local cm_name
        cm_name=$(_sdk_configmap_name)
        if [ -z "$cm_name" ]; then
            return 0
        fi

        local current
        current=$(kubectl get "configmap/${cm_name}" -n "${PLATFORM_NS}" \
          -o jsonpath='{.data.sdk-config\.yaml}' 2>/dev/null || true)

        if ! echo "$current" | grep -q 'prometheus/metrics:' 2>/dev/null; then
            return 0
        fi
        if echo "$current" | grep -A1 'prometheus/metrics:' | grep -q 'enabled: false'; then
            return 0
        fi

        current=$(echo "$current" | sed '/prometheus\/metrics:/{n;s/enabled: true/enabled: false/;}')
        kubectl patch "configmap/${cm_name}" -n "${PLATFORM_NS}" --type merge \
          -p "{\"data\":{\"sdk-config.yaml\":$(echo "$current" | jq -Rs .)}}" >/dev/null 2>&1
        kubectl rollout restart deployment/kubernaut-agent -n "${PLATFORM_NS}" >/dev/null 2>&1
        kubectl rollout status deployment/kubernaut-agent -n "${PLATFORM_NS}" --timeout=120s >/dev/null 2>&1
        echo "  Prometheus toolset disabled via SDK ConfigMap."
    fi
}

# ── Production approval enforcement ──────────────────────────────────────────
# The default approval.rego only requires manual approval for production
# environments when confidence is below 0.8. Since LLM confidence varies
# between runs, production scenarios that expect deterministic approval gates
# call force_production_approval to remove the confidence condition.
#
# The original policy is saved as a base64 annotation so that
# restore_production_approval (called from cleanup.sh) can put it back.
#
# Idempotent: calling force twice without a restore in between is safe —
# the annotation preserves the original, not the already-patched version.

force_production_approval() {
    local ns="${PLATFORM_NS:-kubernaut-system}"
    echo "==> Enforcing deterministic production approval policy..."

    local current_rego existing_b64
    existing_b64=$(kubectl get configmap aianalysis-policies -n "${ns}" \
      -o jsonpath='{.metadata.annotations.kubernaut\.ai/original-approval-rego}' 2>/dev/null || echo "")

    if [ -n "${existing_b64}" ]; then
        current_rego=$(echo "${existing_b64}" | base64 -d)
        kubectl patch configmap aianalysis-policies -n "${ns}" --type=merge \
          -p "{\"data\":{\"approval.rego\":$(echo "${current_rego}" | jq -Rs .)}}"
    else
        current_rego=$(kubectl get configmap aianalysis-policies -n "${ns}" \
          -o jsonpath='{.data.approval\.rego}')
    fi

    kubectl annotate configmap aianalysis-policies -n "${ns}" \
      "kubernaut.ai/original-approval-rego=$(echo "${current_rego}" | base64 | tr -d '\n')" --overwrite

    local patched
    patched=$(python3 -c "
import sys, re
text = sys.stdin.read()
# Match both multi-line (newline-separated) and compact (semicolon-separated) formats
text = re.sub(
    r'require_approval if \{[\s;]*is_production[\s;]+not is_high_confidence[\s;]*\}',
    'require_approval if { is_production }',
    text
)
text = re.sub(
    r'(risk_factors contains \{\"score\": 70, \"reason\": \"Production environment requires manual approval\"\} if \{)[\s;]*is_production[\s;]+not is_high_confidence[\s;]*\}',
    r'\1\n    is_production\n}',
    text
)
print(text, end='')
" <<< "${current_rego}")

    kubectl patch configmap aianalysis-policies -n "${ns}" --type=merge \
      -p "{\"data\":{\"approval.rego\":$(echo "${patched}" | jq -Rs .)}}"
    kubectl rollout restart deployment/aianalysis-controller -n "${ns}"
    kubectl rollout status deployment/aianalysis-controller -n "${ns}" --timeout=60s
    echo "  Approval policy patched: production environments always require manual approval."
}

restore_production_approval() {
    local ns="${PLATFORM_NS:-kubernaut-system}"
    local saved_b64
    saved_b64=$(kubectl get configmap aianalysis-policies -n "${ns}" \
      -o jsonpath='{.metadata.annotations.kubernaut\.ai/original-approval-rego}' 2>/dev/null || echo "")
    if [ -z "${saved_b64}" ]; then
        return 0
    fi
    local original
    original=$(echo "${saved_b64}" | base64 -d)
    kubectl patch configmap aianalysis-policies -n "${ns}" --type=merge \
      -p "{\"data\":{\"approval.rego\":$(echo "${original}" | jq -Rs .)}}"
    kubectl annotate configmap aianalysis-policies -n "${ns}" \
      "kubernaut.ai/original-approval-rego-" 2>/dev/null || true
    kubectl rollout restart deployment/aianalysis-controller -n "${ns}" 2>/dev/null || true
    echo "  Approval policy restored to original."
}

# ── EM configuration helpers ──────────────────────────────────────────────
#
# Scenarios with fast-recurring faults (e.g. memory leaks) need the EM to
# complete its assessment before the alert re-fires.  These helpers let
# each scenario set its own stabilizationWindow / validityWindow and
# restore them afterwards.
#
#   configure_em  <stabilizationWindow> <validityWindow>
#   restore_em
#
# The original YAML is saved as an annotation so restore_em can put it back.
# Idempotent: calling configure_em twice preserves the first saved copy.

configure_em() {
    local stab="${1:?usage: configure_em <stabilizationWindow> <validityWindow>}"
    local val="${2:?usage: configure_em <stabilizationWindow> <validityWindow>}"
    local ns="${PLATFORM_NS:-kubernaut-system}"
    local cm="effectivenessmonitor-config"

    local existing_b64
    existing_b64=$(kubectl get configmap "${cm}" -n "${ns}" \
      -o jsonpath='{.metadata.annotations.kubernaut\.ai/original-em-config}' 2>/dev/null || echo "")

    local current_yaml
    current_yaml=$(kubectl get configmap "${cm}" -n "${ns}" \
      -o jsonpath='{.data.effectivenessmonitor\.yaml}')

    if [ -z "${existing_b64}" ]; then
        kubectl annotate configmap "${cm}" -n "${ns}" \
          "kubernaut.ai/original-em-config=$(echo "${current_yaml}" | base64 | tr -d '\n')" --overwrite
    fi

    local patched
    patched=$(python3 -c "
import sys, yaml
data = yaml.safe_load(sys.stdin.read())
data.setdefault('assessment', {})
data['assessment']['stabilizationWindow'] = '${stab}'
data['assessment']['validityWindow'] = '${val}'
print(yaml.dump(data, default_flow_style=False), end='')
" <<< "${current_yaml}")

    kubectl patch configmap "${cm}" -n "${ns}" --type=merge \
      -p "{\"data\":{\"effectivenessmonitor.yaml\":$(echo "${patched}" | jq -Rs .)}}"
    kubectl rollout restart deployment/effectivenessmonitor-controller -n "${ns}"
    kubectl rollout status deployment/effectivenessmonitor-controller -n "${ns}" --timeout=60s
    echo "  EM configured: stabilizationWindow=${stab}, validityWindow=${val}"
}

restore_em() {
    local ns="${PLATFORM_NS:-kubernaut-system}"
    local cm="effectivenessmonitor-config"
    local saved_b64
    saved_b64=$(kubectl get configmap "${cm}" -n "${ns}" \
      -o jsonpath='{.metadata.annotations.kubernaut\.ai/original-em-config}' 2>/dev/null || echo "")
    if [ -z "${saved_b64}" ]; then
        return 0
    fi
    local original
    original=$(echo "${saved_b64}" | base64 -d)
    kubectl patch configmap "${cm}" -n "${ns}" --type=merge \
      -p "{\"data\":{\"effectivenessmonitor.yaml\":$(echo "${original}" | jq -Rs .)}}"
    kubectl annotate configmap "${cm}" -n "${ns}" \
      "kubernaut.ai/original-em-config-" 2>/dev/null || true
    kubectl rollout restart deployment/effectivenessmonitor-controller -n "${ns}" 2>/dev/null || true
    kubectl rollout status deployment/effectivenessmonitor-controller -n "${ns}" --timeout=60s 2>/dev/null || true
    echo "  EM configuration restored to original."
}
