#!/usr/bin/env bash
# VM Boot Failure Demo -- Automated Runner
# Scenario #376: Bad DataVolume source URL -> VM stuck Provisioning -> fix DV source
#
# Prerequisites:
#   - OCP cluster with OpenShift Virtualization (CNV) installed
#   - Kubernaut services running
#   - Prometheus with KubeVirt metrics
#
# Usage: ./scenarios/vm-boot-failure/run.sh [--auto-approve|--interactive|--no-validate]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-vm-boot"

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
# shellcheck source=../../scripts/monitoring-helper.sh
source "${SCRIPT_DIR}/../../scripts/monitoring-helper.sh"
# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

require_infra cnv
require_infra cdi

enable_prometheus_toolset
force_production_approval

echo "============================================="
echo " VM Boot Failure Remediation Demo (#376)"
echo "============================================="
echo ""

# Step 0: Clean up stale alerts/RRs from any previous run
ensure_clean_slate "${NAMESPACE}"

# Step 1: Preflight
echo "==> Step 1: Preflight checks..."
preflight_check metrics-pipeline alert-quiescent:${NAMESPACE}

# Step 1b: Inject KubeVirt priority rules into SP policy.rego
echo "==> Step 1b: Injecting KubeVirt priority escalation into SP policy.rego..."

EXISTING_B64=$(kubectl get configmap signalprocessing-policy -n "${PLATFORM_NS}" \
  -o jsonpath='{.metadata.annotations.kubernaut\.ai/original-policy-rego}' 2>/dev/null || echo "")
if [ -n "${EXISTING_B64}" ]; then
    echo "  Restoring original policy from previous run's annotation..."
    ORIGINAL_POLICY=$(echo "${EXISTING_B64}" | base64 -d)
    kubectl patch configmap signalprocessing-policy -n "${PLATFORM_NS}" --type=merge \
      -p "{\"data\":{\"policy.rego\":$(echo "${ORIGINAL_POLICY}" | jq -Rs .)}}"
else
    ORIGINAL_POLICY=$(kubectl get configmap signalprocessing-policy -n "${PLATFORM_NS}" \
      -o jsonpath='{.data.policy\.rego}')
fi

kubectl annotate configmap signalprocessing-policy -n "${PLATFORM_NS}" \
  "kubernaut.ai/original-policy-rego=$(echo "${ORIGINAL_POLICY}" | base64)" --overwrite

KUBEVIRT_RULES=$(grep -v -E '^(package |import )' "${SCRIPT_DIR}/rego/kubevirt-priority.rego")

PATCHED_POLICY=$(echo "${ORIGINAL_POLICY}" | sed 's/priority := {"priority": "P2", "policy_name": "staging-any"} if {/priority := {"priority": "P2", "policy_name": "staging-any"} if {\n    not _is_kubevirt_signal/')

MERGED_POLICY="${PATCHED_POLICY}

${KUBEVIRT_RULES}"

kubectl patch configmap signalprocessing-policy -n "${PLATFORM_NS}" --type=merge \
  -p "{\"data\":{\"policy.rego\":$(echo "${MERGED_POLICY}" | jq -Rs .)}}"

echo "  Waiting for SP controller to hot-reload policy..."
sleep 5
echo ""

# Step 2: Deploy scenario resources (VM with broken DataVolume source)
echo "==> Step 2: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"
echo "  Manifests applied."
echo ""

# Step 3: Wait for VM to exist and DataVolume to start importing
echo "==> Step 3: Waiting for VM and DataVolume to be created..."
_elapsed=0
while true; do
    DV_PHASE=$(kubectl get datavolume legacy-app-rootdisk -n "${NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ -n "$DV_PHASE" ]; then
        echo "  DataVolume phase: ${DV_PHASE}"
        break
    fi
    if [ "$_elapsed" -ge 120 ]; then
        echo "  WARNING: DataVolume not created after 120s"
        kubectl get vm,dv -n "${NAMESPACE}" 2>/dev/null
        break
    fi
    sleep 5
    _elapsed=$((_elapsed + 5))
done
echo ""

# Step 4: Show the fault — CDI importer pod will fail to download
echo "==> Step 4: Observing CDI importer failure (bad source URL)..."
echo "  The DataVolume source URL points to a non-existent internal server."
echo "  The CDI importer pod will fail with connection errors."
echo ""
echo "  Waiting for importer pod to appear..."
_elapsed=0
while true; do
    IMPORTER=$(kubectl get pods -n "${NAMESPACE}" -l cdi.kubevirt.io/storage.import.importPvcName=legacy-app-rootdisk \
        --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    if [ -n "$IMPORTER" ]; then
        echo "  Importer pod: ${IMPORTER}"
        sleep 10
        echo "  Importer pod status:"
        kubectl get pod "$IMPORTER" -n "${NAMESPACE}" 2>/dev/null || true
        echo ""
        echo "  Importer pod logs (last 10 lines):"
        kubectl logs "$IMPORTER" -n "${NAMESPACE}" --tail=10 2>/dev/null || echo "  (no logs yet)"
        break
    fi
    if [ "$_elapsed" -ge 120 ]; then
        echo "  WARNING: Importer pod did not appear after 120s"
        kubectl get pods -n "${NAMESPACE}" 2>/dev/null
        break
    fi
    sleep 5
    _elapsed=$((_elapsed + 5))
done
echo ""

# Step 5: Wait for alert to fire
echo "==> Step 5: Waiting for KubeVirtVMProvisioningStuck alert (~3-5 min)..."
echo "  The alert fires after the DataVolume is stuck pending for >2 min."
echo ""
echo "  Current VM status:"
kubectl get vm -n "${NAMESPACE}" 2>/dev/null || true
echo ""

# Step 6: Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
