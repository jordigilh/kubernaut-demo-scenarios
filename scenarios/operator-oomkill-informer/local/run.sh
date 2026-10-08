#!/usr/bin/env bash
# Operator OOMKill from Informer Cache Flooding -- Automated Runner
# Based on kubeflow/spark-operator#2878: unfiltered ConfigMap informer
# cache allows any user with "edit" ClusterRole to OOMKill the operator.
#
# Supports Kind and OpenShift clusters.
#
# Prerequisites:
#   - Kind or OCP cluster with Kubernaut services
#   - Prometheus with kube-state-metrics scraping
#
# Usage: ./scenarios/operator-oomkill-informer/run.sh [--auto-approve|--interactive]
# Single-cluster (local) path. For fleet mode (HUB_KUBECONFIG +
# SPOKE_KUBECONFIG set), the top-level run.sh dispatches to ../fleet/run.sh
# instead -- see scripts/fleet-helper.sh.
set -euo pipefail

# SCRIPT_DIR resolves to the scenario directory (one level up from this
# script's own local/ subdirectory).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-controllers"

APPROVE_MODE="--auto-approve"
SKIP_VALIDATE=""
ALERT_ONLY=""
for _arg in "$@"; do
    case "$_arg" in
        --auto-approve)  APPROVE_MODE="--auto-approve" ;;
        --interactive)   APPROVE_MODE="--interactive" ;;
        --no-validate)   SKIP_VALIDATE=true ;;
        --alert-only)    ALERT_ONLY=true ;;
    esac
done

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
require_demo_ready
# shellcheck source=../../scripts/monitoring-helper.sh
source "${SCRIPT_DIR}/../../scripts/monitoring-helper.sh"
require_infra metrics-server
if ! kubectl get apiservice v1beta1.metrics.k8s.io \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q True; then
    echo "ERROR: Kubernetes Metrics API is unavailable. Check metrics-server before running this scenario; workload CPU/memory must be available to kubectl top." >&2
    exit 1
fi
# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

enable_prometheus_toolset
force_production_approval

echo "============================================="
echo " Operator OOMKill: Informer Cache Flooding"
echo " CVE: kubeflow/spark-operator#2878"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying operator and RBAC..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"
# The repository manifests carry Argo CD ownership for the fleet path. A
# single-cluster run has no Argo CD Application, so remove only the live
# ownership markers and keep the established direct IncreaseMemoryLimits
# workflow contract for this non-GitOps mode. The source manifests remain
# GitOps-ready for fleet/hub.sh.
kubectl annotate namespace "${NAMESPACE}" argocd.argoproj.io/instance- \
  --ignore-not-found 2>/dev/null || true
kubectl annotate deployment/demo-controllers-controller -n "${NAMESPACE}" \
  argocd.argoproj.io/instance- --ignore-not-found 2>/dev/null || true

# Step 2: Wait for operator to be healthy
echo "==> Step 2: Waiting for operator to be ready..."
kubectl wait --for=condition=Available deployment/demo-controllers-controller \
  -n "${NAMESPACE}" --timeout=120s
echo "  Operator is running with 128Mi memory limit."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 3: Establish baseline
echo "==> Step 3: Establishing healthy baseline (10s)..."
sleep 10
echo "  Baseline established. Operator healthy, 0 restarts."
echo ""

# Step 4: Inject ConfigMap flood
echo "==> Step 4: Flooding namespace with 100 x 1MB ConfigMaps..."
echo "  This mirrors the attack vector from the Spark Operator CVE."
echo "  Any user with the standard 'edit' ClusterRole can do this."
echo ""
bash "${SCRIPT_DIR}/inject-configmap-flood.sh"
echo ""

# Step 5: Wait for OOMKill and CrashLoop
echo "==> Step 5: Waiting for operator to OOMKill (~30-60s)..."
echo "  The informer cache deserializes all ConfigMaps into Go structs."
echo "  ~100MB raw data far exceeds the 128Mi memory limit."
echo ""
sleep 15
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "  Waiting for restarts to accumulate..."
sleep 30
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "  The KubePodCrashLooping alert fires after sustained restarts."
echo ""

# Step 6: Validate pipeline
if [ "${ALERT_ONLY}" = "true" ]; then
    echo ""
    echo "==> Waiting for alert (--alert-only mode)..."
    wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 480
    show_alert "KubePodCrashLooping" "${NAMESPACE}"
    echo ""
    echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
    echo "    Exiting without entering validation pipeline."
elif [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    OPERATOR_GITOPS_LOCAL_DIRECT=true bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
