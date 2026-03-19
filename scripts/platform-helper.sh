#!/usr/bin/env bash
# Shared platform deployment helpers for demo scenarios.
# Source this from run.sh:
#   source "$(dirname "$0")/../../scripts/platform-helper.sh"

PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_REF="oci://quay.io/kubernaut-ai/charts/kubernaut"
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
        local applied=0 skipped=0
        while IFS= read -r -d '' yaml_file; do
            local basename="${yaml_file##*/}"

            # Skip Ansible-engine workflows (require AWX infrastructure)
            if grep -q 'engine: ansible' "$yaml_file"; then
                echo "    SKIP ${basename} (engine: ansible — requires AWX)"
                skipped=$((skipped + 1))
                continue
            fi

            # Check secret dependencies declared in the workflow
            local unmet=""
            while IFS= read -r secret_name; do
                if ! kubectl get secret "$secret_name" -n "${ns}" &>/dev/null; then
                    unmet="${secret_name}"
                    break
                fi
            done < <(grep -A1 'secrets:' "$yaml_file" 2>/dev/null \
                      | grep -- '- name:' | awk '{print $NF}')

            if [ -n "$unmet" ]; then
                echo "    SKIP ${basename} (secret \"${unmet}\" not found in ${ns})"
                skipped=$((skipped + 1))
                continue
            fi

            kubectl apply -n "$ns" -f "$yaml_file" 2>&1 \
                | grep -v unchanged | sed 's/^/    /' || true
            applied=$((applied + 1))
        done < <(find "$wf_dir" -name '*.yaml' -print0)
        echo "    Applied ${applied} workflow(s), skipped ${skipped}."
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

    if [ "$fail" = false ] && ! helm status kubernaut -n "${PLATFORM_NS}" &>/dev/null; then
        echo "ERROR: Kubernaut platform is not installed in ${PLATFORM_NS}."
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

    seed_action_types_and_workflows
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
    if helm status kubernaut -n "${PLATFORM_NS}" &>/dev/null; then
        echo "  Kubernaut platform already installed."
        _check_llm_credentials
        return 0
    fi

    echo "==> Installing Kubernaut platform..."

    _ensure_pre_install_secrets

    echo "  Applying CRDs..."
    local _crd_tmp
    _crd_tmp=$(mktemp -d)
    helm pull "${CHART_REF}" --untar --untardir "${_crd_tmp}" 2>&1 | sed 's/^/    /'
    kubectl apply -f "${_crd_tmp}/kubernaut/crds/" 2>&1 | sed 's/^/    /'
    rm -rf "${_crd_tmp}"

    local llm_flags=""
    if [ -f "${SDK_CONFIG}" ]; then
        llm_flags="--set-file holmesgptApi.sdkConfigContent=${SDK_CONFIG}"
        echo "  SDK config loaded from ${SDK_CONFIG}"
    elif [ -n "${KUBERNAUT_LLM_PROVIDER:-}" ] && [ -n "${KUBERNAUT_LLM_MODEL:-}" ]; then
        llm_flags="--set holmesgptApi.llm.provider=${KUBERNAUT_LLM_PROVIDER} --set holmesgptApi.llm.model=${KUBERNAUT_LLM_MODEL}"
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

    local version_flag=""
    if [ -n "${CHART_VERSION:-}" ]; then
        version_flag="--version ${CHART_VERSION}"
        echo "  Installing Helm chart (version: ${CHART_VERSION}, platform: ${PLATFORM})..."
    else
        echo "  Installing Helm chart (platform: ${PLATFORM})..."
    fi
    helm upgrade --install kubernaut "${CHART_REF}" \
        --namespace "${PLATFORM_NS}" \
        --create-namespace \
        --values "${values_file}" \
        ${llm_flags} \
        ${version_flag} \
        --set demoContent.enabled=false \
        --skip-crds \
        --wait --timeout 10m

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

# Create secrets that must exist before Helm install:
#   - llm-credentials (VertexAI ADC for holmesgpt-api)
#   - slack-webhook (notification credential store, issue #104)
# Also labels the namespace for Helm adoption if it was pre-created.
_ensure_pre_install_secrets() {
    kubectl create namespace "${PLATFORM_NS}" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

    # Helm namespace adoption labels
    kubectl label namespace "${PLATFORM_NS}" app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null
    kubectl annotate namespace "${PLATFORM_NS}" \
        meta.helm.sh/release-name=kubernaut \
        meta.helm.sh/release-namespace="${PLATFORM_NS}" --overwrite 2>/dev/null

    # LLM credentials (VertexAI ADC)
    local adc_file="${HOME}/.config/gcloud/application_default_credentials.json"
    if [ -f "${adc_file}" ] && [ -f "${SDK_CONFIG}" ]; then
        local project region
        project=$(grep 'gcp_project_id' "${SDK_CONFIG}" | awk -F'"' '{print $2}')
        region=$(grep 'gcp_region' "${SDK_CONFIG}" | awk -F'"' '{print $2}')
        if [ -n "${project}" ] && [ -n "${region}" ]; then
            kubectl create secret generic llm-credentials \
                -n "${PLATFORM_NS}" \
                --from-literal=VERTEXAI_PROJECT="${project}" \
                --from-literal=VERTEXAI_LOCATION="${region}" \
                --from-literal=GOOGLE_APPLICATION_CREDENTIALS="/etc/holmesgpt/credentials/application_default_credentials.json" \
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

    # DB, DataStorage, and Valkey Secrets are auto-generated by the
    # v1.1.0 chart (randAlphaNum + lookup). No pre-creation needed.
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
        echo "    kubectl rollout restart deployment/holmesgpt-api -n ${PLATFORM_NS}"
        echo ""
    fi
}
