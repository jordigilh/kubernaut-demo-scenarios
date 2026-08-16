#!/usr/bin/env bash
# Seed the signalprocessing-policy and AIAnalysis approval-policy Rego
# ConfigMaps from deploy/defaults/.
#
# The Helm chart accepts these via --set-file (signalprocessing.policies.content /
# aianalysis.policies.content), but kubernaut-operator installs intentionally do
# NOT create them -- they're a documented "user-provided prerequisite" (see
# kubernaut-operator/internal/controller/kubernaut_lifecycle_test.go). Without
# this script (or the equivalent Helm --set-file flags), SignalProcessing and
# AIAnalysis have no working policy and every real investigation fails at
# environment classification / approval gating.
#
# Mirrors seed-action-types.sh / seed-workflows.sh: safe to (re-)run any time,
# regardless of install method.
#
# ConfigMap naming gotcha (see issue #403): the Helm chart and this repo's own
# kustomize base (base/platform/aianalysis.yaml) both name the AIAnalysis
# ConfigMap "aianalysis-policies" (plural), but kubernaut-operator's default
# (when the Kubernaut CR's spec.aiAnalysis.policy.configMapName is unset) is
# "aianalysis-policy" (singular) -- confirmed in
# kubernaut-operator/internal/resources/common.go. Seeding the wrong name on
# an operator-managed cluster silently leaves AIAnalysis unconfigured. This
# script detects the install method and, for operator installs, prefers the
# name the live Kubernaut CR actually references.
#
# Usage:
#   ./scripts/seed-policies.sh
#   ./scripts/seed-policies.sh --namespace my-ns
#
# See: https://github.com/jordigilh/kubernaut-demo-scenarios/issues/403

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${PLATFORM_NS:-kubernaut-system}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--namespace NAMESPACE]"
            echo ""
            echo "Applies the canonical Rego policies from deploy/defaults/ as the"
            echo "signalprocessing-policy and AIAnalysis approval-policy ConfigMaps."
            echo "Required on kubernaut-operator installs, which do not create these"
            echo "ConfigMaps automatically (Helm installs should prefer the chart's"
            echo "--set-file signalprocessing.policies.content / aianalysis.policies.content"
            echo "flags, but running this afterward is a harmless no-op refresh)."
            echo ""
            echo "Default namespace: kubernaut-system (override with --namespace or"
            echo "\$PLATFORM_NS)."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

SP_POLICY="${SCRIPT_DIR}/../deploy/defaults/signalprocessing-policy.rego"
AA_POLICY="${SCRIPT_DIR}/../deploy/defaults/approval-policy.rego"
SP_CONFIGMAP="signalprocessing-policy"

# Resolve the AIAnalysis ConfigMap name for the detected install method.
# Default assumes Helm/kustomize (this repo's own base/ manifests and the
# Helm chart both hardcode the plural name). Operator installs override this
# below with whatever the live CR actually references.
AA_CONFIGMAP="aianalysis-policies"
_kn_name=$(kubectl get kubernaut -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "${_kn_name}" ]; then
    _cr_cm_name=$(kubectl get kubernaut "${_kn_name}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.aiAnalysis.policy.configMapName}' 2>/dev/null || true)
    if [ -n "${_cr_cm_name}" ]; then
        AA_CONFIGMAP="${_cr_cm_name}"
    else
        # Kubernaut CR present but configMapName left empty (v1alpha1-style
        # defaulting) -- operator's hardcoded default is singular.
        AA_CONFIGMAP="aianalysis-policy"
    fi
    echo "==> Detected operator-managed install (Kubernaut/${_kn_name}); AIAnalysis ConfigMap: ${AA_CONFIGMAP}"
elif helm status kubernaut -n "${NAMESPACE}" &>/dev/null; then
    echo "==> Detected Helm-managed install; AIAnalysis ConfigMap: ${AA_CONFIGMAP}"
else
    echo "==> No Kubernaut CR or Helm release found in ${NAMESPACE}; assuming kustomize-style install (${AA_CONFIGMAP})"
fi

fail_count=0

if [ ! -f "$SP_POLICY" ]; then
    echo "ERROR: ${SP_POLICY} not found"
    fail_count=$((fail_count + 1))
else
    echo -n "  ${SP_CONFIGMAP} (policy.rego) -> namespace/${NAMESPACE}: "
    if kubectl create configmap "${SP_CONFIGMAP}" -n "${NAMESPACE}" \
        --from-file=policy.rego="${SP_POLICY}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null; then
        echo "APPLIED"
    else
        echo "FAILED"
        fail_count=$((fail_count + 1))
    fi
fi

if [ ! -f "$AA_POLICY" ]; then
    echo "ERROR: ${AA_POLICY} not found"
    fail_count=$((fail_count + 1))
else
    echo -n "  ${AA_CONFIGMAP} (approval.rego) -> namespace/${NAMESPACE}: "
    if kubectl create configmap "${AA_CONFIGMAP}" -n "${NAMESPACE}" \
        --from-file=approval.rego="${AA_POLICY}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null; then
        echo "APPLIED"
    else
        echo "FAILED"
        fail_count=$((fail_count + 1))
    fi
fi

echo ""
if [ "$fail_count" -eq 0 ]; then
    echo "==> Done. Both policy ConfigMaps are in place in namespace/${NAMESPACE}."
    echo "    Both controllers hot-reload policy content; no restart needed."
else
    echo "==> ${fail_count} failure(s). See above."
fi

echo "  Verify: kubectl get configmap ${SP_CONFIGMAP} ${AA_CONFIGMAP} -n ${NAMESPACE}"

[ "$fail_count" -eq 0 ]
