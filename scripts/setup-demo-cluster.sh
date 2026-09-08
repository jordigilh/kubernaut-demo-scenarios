#!/usr/bin/env bash
# Set up demo dependencies and catalog content on an existing cluster.
#
# The upstream Kubernaut repository owns cluster and core-platform bootstrap.
# This script installs the remaining demo dependencies and seeds policies,
# ActionTypes, and RemediationWorkflows. In fleet mode, all control-plane
# resources are applied to HUB_KUBECONFIG; the spoke is never used for
# credentials or catalog content.
#
# Usage:
#   ./scripts/setup-demo-cluster.sh
#   ./scripts/setup-demo-cluster.sh --skip-infra
#   ./scripts/setup-demo-cluster.sh --with-awx
#
# Local setup uses the ambient KUBECONFIG. Fleet setup requires:
#   HUB_KUBECONFIG=/path/to/hub.yaml \
#   SPOKE_KUBECONFIG=/path/to/spoke.yaml \
#   ./scripts/setup-demo-cluster.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_DIR="${SCRIPT_DIR}/../scenarios"

SKIP_INFRA=false
WITH_AWX=false
FLEET_MODE=false
export CHART_VERSION="${CHART_VERSION:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-infra)
            SKIP_INFRA=true
            shift
            ;;
        --with-awx)
            WITH_AWX=true
            shift
            ;;
        --chart-version)
            CHART_VERSION="$2"
            export CHART_VERSION
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--skip-infra] [--with-awx] [--chart-version VERSION]"
            echo ""
            echo "The cluster must already be bootstrapped. Local mode uses KUBECONFIG;"
            echo "fleet mode requires HUB_KUBECONFIG and SPOKE_KUBECONFIG."
            echo ""
            echo "Options:"
            echo "  --skip-infra          Skip optional demo dependencies (Gitea, ArgoCD, etc.)"
            echo "  --with-awx            Install AWX Operator for Ansible engine demos (#312)"
            echo "  --chart-version VER   Pin the Kubernaut chart version"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -n "${HUB_KUBECONFIG:-}" ] || [ -n "${SPOKE_KUBECONFIG:-}" ]; then
    if [ -z "${HUB_KUBECONFIG:-}" ] || [ -z "${SPOKE_KUBECONFIG:-}" ]; then
        echo "ERROR: fleet setup requires both HUB_KUBECONFIG and SPOKE_KUBECONFIG."
        exit 1
    fi
    FLEET_MODE=true
    export KUBECONFIG="${HUB_KUBECONFIG}"
    # NOTE: FLEET_EXECUTION_CLUSTER_ID used to be auto-detected from the raw
    # prometheus-config ConfigMap (a `cluster:` global in prometheus.yml).
    # Upstream now deploys an operator-managed Prometheus (no such ConfigMap),
    # so an explicit export is the only override; otherwise seed-workflows.sh
    # falls back to its hardcoded default ("hub").
elif [ -z "${KUBECONFIG:-}" ]; then
    echo "ERROR: KUBECONFIG must identify an existing local cluster."
    echo "       For fleet setup, set HUB_KUBECONFIG and SPOKE_KUBECONFIG."
    exit 1
fi

TOTAL_START=$(date +%s)

echo "============================================="
echo " Kubernaut Demo Environment Setup"
echo "============================================="
echo ""

if [ "$FLEET_MODE" = true ]; then
    echo "==> Fleet mode: configuring hub ${HUB_KUBECONFIG}"
    echo "    Spoke remains available at ${SPOKE_KUBECONFIG} for scenario runners."
else
    echo "==> Local mode: configuring ${KUBECONFIG}"
fi
echo ""

# ── 1. Existing platform ────────────────────────────────────────────────────

echo "==> Phase 1: Kubernaut platform"
# shellcheck source=platform-helper.sh
source "${SCRIPT_DIR}/platform-helper.sh"
ensure_platform
echo ""

# Upstream's fleet bootstrap owns the hub/spoke monitoring and fleet services.
# The local bootstrap path may still need the shared demo dependencies.
if [ "$FLEET_MODE" = false ]; then
    # ── 2. Local monitoring and infrastructure dependencies ─────────────────
    if [ "$SKIP_INFRA" = false ]; then
        echo "==> Phase 2: Monitoring stack"
        # shellcheck source=monitoring-helper.sh
        source "${SCRIPT_DIR}/monitoring-helper.sh"
        ensure_monitoring_stack
        echo ""

        echo "==> Phase 3: Infrastructure dependencies"
        echo "--- cert-manager ---"
        ensure_cert_manager
        echo ""
        echo "--- metrics-server ---"
        ensure_metrics_server
        echo ""
        echo "--- Istio ---"
        ensure_istio
        echo ""
        echo "--- blackbox-exporter ---"
        ensure_blackbox_exporter
        echo ""
    else
        echo "==> Phases 2-3: Skipping local infrastructure (--skip-infra)"
        echo ""
    fi
fi

# ── 2/4. GitOps infrastructure ─────────────────────────────────────────────
# In fleet mode this entire phase runs against the hub. The spoke must never
# receive the repository credential.

if [ "$SKIP_INFRA" = false ]; then
    echo "==> GitOps infrastructure (hub/control-plane context)"

    echo "--- Gitea ---"
    if kubectl get namespace gitea &>/dev/null; then
        echo "  Gitea already installed."
    else
        bash "${SCENARIOS_DIR}/gitops/scripts/setup-gitea.sh"
    fi
    echo ""

    echo "--- ArgoCD ---"
    bash "${SCENARIOS_DIR}/gitops/scripts/setup-argocd.sh"
    echo ""
fi

# ── Optional AWX ─────────────────────────────────────────────────────────────

if [ "$WITH_AWX" = true ] && [ "$SKIP_INFRA" = false ]; then
    echo "==> AWX (Ansible engine)"
    if kubectl get deployment -n kubernaut-system -l app.kubernetes.io/managed-by=awx-operator --no-headers 2>/dev/null | grep -q .; then
        echo "  AWX already installed."
    else
        bash "${SCRIPT_DIR}/awx-helper.sh"
    fi
    echo ""
fi

# ── Catalog and policy content ──────────────────────────────────────────────

echo "==> Seeding policy ConfigMaps"
bash "${SCRIPT_DIR}/seed-policies.sh"
echo ""

echo "==> Seeding ActionType CRDs (must exist before workflows)"
bash "${SCRIPT_DIR}/seed-action-types.sh" --continue-on-error --skip-wait
echo ""

echo "==> Seeding workflow catalog"
bash "${SCRIPT_DIR}/seed-workflows.sh" --continue-on-error
echo ""

# ── Final validation ─────────────────────────────────────────────────────────

echo "==> Final readiness validation"
echo ""

NAMESPACES=("kubernaut-system" "kubernaut-workflows")
if [ "$SKIP_INFRA" = false ]; then
    NAMESPACES+=("gitea" "$(get_argocd_namespace)")
    if [ "$FLEET_MODE" = false ]; then
        NAMESPACES+=("monitoring" "cert-manager" "istio-system")
    fi
fi

all_ready=true
for ns in "${NAMESPACES[@]}"; do
    if ! kubectl get namespace "$ns" &>/dev/null; then
        echo "  WARNING: namespace ${ns} does not exist"
        all_ready=false
        continue
    fi
    local_deps=$(kubectl get deployments -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [ -z "$local_deps" ]; then
        continue
    fi
    for dep in $local_deps; do
        ready=$(kubectl get deployment "$dep" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        desired=$(kubectl get deployment "$dep" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null)
        if [ "${ready:-0}" != "${desired:-1}" ]; then
            echo "  WARNING: ${ns}/${dep} not ready (${ready:-0}/${desired:-1})"
            all_ready=false
        fi
    done
done

if [ "$FLEET_MODE" = true ]; then
    if kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get secret gitea-repo-creds \
        -n kubernaut-workflows &>/dev/null; then
        echo "  ERROR: gitea-repo-creds must not exist on the spoke."
        all_ready=false
    else
        echo "  OK: gitea-repo-creds is absent from the spoke."
    fi
fi

TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - TOTAL_START))
total_mins=$((TOTAL_DURATION / 60))
total_secs=$((TOTAL_DURATION % 60))

echo ""
echo "============================================="
if [ "$all_ready" = true ]; then
    echo " Demo environment ready! (${total_mins}m ${total_secs}s)"
else
    echo " Demo environment setup complete with warnings (${total_mins}m ${total_secs}s)"
fi
echo "============================================="
echo ""
echo "Run any scenario:"
echo "  bash scenarios/crashloop/run.sh"
echo ""
echo "Or use the orchestrator:"
echo "  bash scripts/run-scenario.sh --scenario crashloop --auto-approve"
