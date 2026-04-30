#!/usr/bin/env bash
# Route misconfiguration demo -- bad Route target -> 503 -> FixRouteTarget
#
# Prerequisites:
#   - OpenShift cluster with Kubernaut services and HAProxy router metrics
#
# Usage: ./scenarios/route-misconfiguration/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-route"

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
echo " Route Misconfiguration Remediation Demo"
echo " Bad route target -> 503 errors"
echo " -> FixRouteTarget"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

echo "==> Step 2: Waiting for deployment and Route..."
kubectl wait --for=condition=Available deployment/storefront-web -n "${NAMESPACE}" --timeout=120s
_admitted=""
for _i in $(seq 1 60); do
    if [ "$(kubectl get route storefront -n "${NAMESPACE}" -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}' 2>/dev/null)" = "True" ]; then
        _admitted=1
        break
    fi
    sleep 2
done
if [ -z "${_admitted}" ]; then
    echo "ERROR: Route storefront not admitted within timeout" >&2
    exit 1
fi
echo "  storefront-web is Available; Route storefront is admitted."
kubectl get pods -n "${NAMESPACE}"
echo ""

echo "==> Step 3: Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established."
echo ""

echo "==> Step 4: Injecting bad Route target (non-existent Service)..."
bash "${SCRIPT_DIR}/inject-bad-route.sh"
echo ""

echo "==> Step 5: Waiting for RouteBackendUnavailable alert (~2-3 min)..."
echo "  The Route now targets storefront-web-v2 which does not exist."
echo ""
sleep 10
kubectl get route storefront -n "${NAMESPACE}"
kubectl get pods -n "${NAMESPACE}"
echo ""
sleep 30
kubectl get route storefront -n "${NAMESPACE}"
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "  Check Prometheus: kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""

if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
