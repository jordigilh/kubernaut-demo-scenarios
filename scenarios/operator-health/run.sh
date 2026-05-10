#!/usr/bin/env bash
# Usage: ./scenarios/operator-health/run.sh [--auto-approve|--interactive] [--no-validate]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NAMESPACE="${NAMESPACE:-demo-operator}"

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
echo " Operator Health Remediation Demo"
echo " CSV deleted -> operator down"
echo " -> RestoreOperatorCSV"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

# No cluster-wide preflight needed. The alert annotations and signal labels
# direct the LLM to focus on the etcd Subscription in demo-operator.
# Copied CSVs from cluster-scoped operators are harmless -- the alert's
# investigation_scope annotation constrains the LLM's investigation.

echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")

# When NAMESPACE is overridden, create a temp copy of the entire scenario
# tree with the namespace replaced everywhere (YAML metadata, PromQL
# expressions, annotations, kustomize overlay references).
DEFAULT_NS="demo-operator"
if [ "${NAMESPACE}" != "${DEFAULT_NS}" ]; then
    TEMP_SCENARIO_DIR=$(mktemp -d)
    trap 'rm -rf "${TEMP_SCENARIO_DIR}"' EXIT
    cp -r "${SCRIPT_DIR}/manifests" "${TEMP_SCENARIO_DIR}/manifests"
    if [ -d "${SCRIPT_DIR}/overlays" ]; then
        cp -r "${SCRIPT_DIR}/overlays" "${TEMP_SCENARIO_DIR}/overlays"
    fi
    find "${TEMP_SCENARIO_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' \) -exec \
        sed -i.bak "s/${DEFAULT_NS}/${NAMESPACE}/g" {} +
    find "${TEMP_SCENARIO_DIR}" -name '*.bak' -delete
    MANIFEST_DIR=$(get_manifest_dir "${TEMP_SCENARIO_DIR}")
fi

kubectl apply -k "${MANIFEST_DIR}"

echo "==> Step 2: Waiting for InstallPlan..."
IP_NAME=""
for _i in $(seq 1 60); do
    IP_NAME=$(kubectl get installplan -n "${NAMESPACE}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
    if [ -n "${IP_NAME}" ]; then
        break
    fi
    sleep 5
done
if [ -z "${IP_NAME}" ]; then
    echo "ERROR: No InstallPlan created within timeout" >&2
    exit 1
fi
echo "  Approving InstallPlan ${IP_NAME}..."
kubectl patch installplan "${IP_NAME}" -n "${NAMESPACE}" --type=merge -p '{"spec":{"approved":true}}'

echo "==> Step 3: Waiting for etcd operator CSV to reach Succeeded..."
CSV_PHASE=""
for _i in $(seq 1 60); do
    CSV_PHASE=$(kubectl get csv -n "${NAMESPACE}" --no-headers \
      -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null \
      | grep "^etcd" | awk '{print $2}' | head -1 || true)
    if [ "${CSV_PHASE}" = "Succeeded" ]; then
        break
    fi
    sleep 5
done
if [ "${CSV_PHASE}" != "Succeeded" ]; then
    echo "ERROR: etcd CSV did not reach Succeeded within timeout (current: ${CSV_PHASE})" >&2
    exit 1
fi
echo "  Etcd operator CSV is Succeeded."

echo "==> Step 4: Establishing healthy baseline (20s)..."
sleep 20
echo ""

echo "==> Step 5: Deleting CSV to trigger OperatorCSVFailed..."
bash "${SCRIPT_DIR}/inject-broken-csv.sh"
echo ""

kubectl get csv -n "${NAMESPACE}" 2>/dev/null || true
kubectl get pods -n "${NAMESPACE}" 2>/dev/null || true
echo ""

if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
