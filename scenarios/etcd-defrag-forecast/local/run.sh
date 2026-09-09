#!/usr/bin/env bash
# etcd Defrag Forecast Demo -- Automated Runner
# Predictive etcd defragmentation: standalone etcd cluster with injected
# fragmentation, LLM investigates health + fragmentation ratio, workflow
# performs rolling defrag with manual approval gate.
#
# Prerequisites:
#   - OCP cluster with Kubernaut services
#   - DefragEtcd ActionType + defrag-etcd-v1 workflow registered
#   - StorageClass available for etcd PVCs (1Gi each)
#
# Usage: ./scenarios/etcd-defrag-forecast/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-datastore"

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
# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

echo "============================================="
echo " etcd Defrag Forecast Demo"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

# Live-cluster mode (ETCD_LIVE_CLUSTER=1, kind only): fragment the kind
# control-plane etcd in place instead of deploying the demo StatefulSet.
# Uses the local/live assets (proxy + ServiceMonitor + Rule + Jobs) --
# the local kube-prometheus-stack selects all monitoring CRDs, so no
# overlay is needed. With the gateway present locally, the full validate.sh
# pipeline below can drive defrag-etcd-v1 end to end (its execution
# clusterId is empty, so the Job runs where the signal fired).
if [ "${ETCD_LIVE_CLUSTER:-0}" = "1" ]; then
    if [ "$(detect_platform)" != "kind" ]; then
        echo "ERROR: ETCD_LIVE_CLUSTER=1 requires a kind cluster (got: $(detect_platform)) -- the live control-plane etcd is only reachable there. Use the dedicated mode on OCP." >&2
        exit 1
    fi
    LIVE_DIR="${SCRIPT_DIR}/local/live"
    echo "==> Step 1 (live): Applying live-etcd monitoring (proxy + ServiceMonitor + Rule)..."
    kubectl apply -k "${LIVE_DIR}"
    echo ""
    echo "==> Step 2 (live): Waiting for metrics proxy..."
    kubectl wait --for=condition=Available deployment/etcd-metrics-proxy \
        -n "${NAMESPACE}" --timeout=180s
    echo ""
    echo "==> Step 3 (live): Establishing healthy baseline (defrag)..."
    kubectl delete job etcd-live-defrag -n "${NAMESPACE}" --ignore-not-found
    kubectl apply -f "${SCRIPT_DIR}/local/defrag-job.yaml"
    kubectl wait --for=condition=complete job/etcd-live-defrag \
        -n "${NAMESPACE}" --timeout=600s
    echo ""
    echo "==> Step 4 (live): Fragmenting live etcd (loader Job, ~1 min)..."
    kubectl delete job etcd-frag-loader -n "${NAMESPACE}" --ignore-not-found
    kubectl apply -f "${SCRIPT_DIR}/local/loader-job.yaml"
    kubectl wait --for=condition=complete job/etcd-frag-loader \
        -n "${NAMESPACE}" --timeout=900s
    echo ""
    echo "==> Live etcd fragmented. Remediate afterwards by re-applying local/defrag-job.yaml."
else
# Step 1: Deploy etcd cluster
echo "==> Step 1: Deploying 3-member etcd cluster..."
if [ "$(detect_platform)" = "kind" ] \
    && kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' 2>/dev/null | grep -q '^arm64$'; then
    echo "ERROR: the dedicated demo etcd image is amd64-only and cannot run on this arm64 kind cluster." >&2
    echo "  Re-run with ETCD_LIVE_CLUSTER=1 to fragment the kind control-plane etcd instead." >&2
    exit 1
fi
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for etcd to form a healthy cluster
echo "==> Step 2: Waiting for etcd StatefulSet to be ready..."
kubectl rollout status statefulset/etcd -n "${NAMESPACE}" --timeout=600s
echo "    etcd cluster ready."
kubectl get pods -n "${NAMESPACE}" -l app=etcd
echo ""

# Step 3: Verify cluster health
echo "==> Step 3: Verifying etcd cluster health..."
kubectl exec etcd-0 -n "${NAMESPACE}" -- \
    etcdctl --endpoints=http://localhost:2379 member list --write-out=table
echo ""

# Step 4: Wait for metrics to be scraped
echo "==> Step 4: Waiting for Prometheus to scrape etcd metrics (60s)..."
sleep 60

# Step 5: Inject fragmentation
echo "==> Step 5: Injecting etcd fragmentation..."
bash "${SCRIPT_DIR}/inject-fragmentation.sh"
echo ""
fi # ETCD_LIVE_CLUSTER

echo "==> Step 6: Waiting for EtcdHighFragmentationRatio alert."
echo "    The alert has a 30s 'for' clause. Expect ~1 min."

# Validate pipeline
if [ "${ALERT_ONLY}" = "true" ]; then
    echo ""
    echo "==> Waiting for alert (--alert-only mode)..."
    wait_for_alert "EtcdHighFragmentationRatio" "${NAMESPACE}" 600
    show_alert "EtcdHighFragmentationRatio" "${NAMESPACE}"
    echo ""
    echo "==> Alert is firing. Scenario ready for AF/A2A remediation."
    echo "    Exiting without entering validation pipeline."
elif [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}" || _rc=$?
fi

exit "${_rc:-0}"
