#!/usr/bin/env bash
# Operator OOMKill from Informer Cache Flooding -- Automated Runner
# Based on kubeflow/spark-operator#2878: unfiltered ConfigMap informer
# cache allows any user with "edit" ClusterRole to OOMKill the operator.
#
# OCP-only scenario.
#
# Prerequisites:
#   - OCP cluster with Kubernaut services
#   - Prometheus with kube-state-metrics scraping
#
# Usage: ./scenarios/operator-oomkill-informer/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-controllers"

APPROVE_MODE="--auto-approve"
SKIP_VALIDATE=""
for _arg in "$@"; do
    case "$_arg" in
        --auto-approve)  APPROVE_MODE="--auto-approve" ;;
        --interactive)   APPROVE_MODE="--interactive" ;;
        --no-validate)   SKIP_VALIDATE=true ;;
    esac
done

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
require_demo_ready
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
kubectl apply -k "${SCRIPT_DIR}/manifests"

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
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
