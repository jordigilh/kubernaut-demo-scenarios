#!/usr/bin/env bash
# Cleanup for cert-manager GitOps Demo (#134)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> Cleaning up cert-manager GitOps demo..."

kubectl delete -f "${SCRIPT_DIR}/manifests/argocd-application.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/prometheus-rule.yaml" --ignore-not-found
kubectl delete -f "${SCRIPT_DIR}/manifests/servicemonitor.yaml" --ignore-not-found
kubectl delete namespace demo-cert-gitops --ignore-not-found
kubectl delete clusterissuer demo-selfsigned-ca-gitops --ignore-not-found
kubectl delete secret demo-ca-key-pair -n cert-manager --ignore-not-found
# FixCertificate workflow may recreate the broken CA secret as its remediation
kubectl delete secret nonexistent-ca-secret -n cert-manager --ignore-not-found

if [ "$PLATFORM" = "ocp" ]; then
    kubectl delete rolebinding prometheus-k8s-read-binding -n cert-manager --ignore-not-found
    kubectl delete role prometheus-k8s-read -n cert-manager --ignore-not-found
    kubectl label namespace cert-manager openshift.io/cluster-monitoring- 2>/dev/null || true
fi

echo "==> Cleanup complete."
echo "    NOTE: Gitea, ArgoCD, and cert-manager are left running for reuse."
