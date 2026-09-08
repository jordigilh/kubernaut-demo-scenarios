#!/usr/bin/env bash
# etcd Defrag Forecast Demo -- Fleet Spoke Steps
#
# Two modes, selected by ETCD_LIVE_CLUSTER (default: dedicated):
#
# - Dedicated (default, all platforms): deploys the 3-member demo etcd
#   StatefulSet and fragments it. Monitoring is operator-native:
#   manifests/servicemonitor.yaml selects the headless Service so all
#   three members are discovered individually with endpoint identity.
# - Live (ETCD_LIVE_CLUSTER=1, kind spokes only): uses the kind
#   control-plane etcd in place -- no demo StatefulSet. A hostNetwork
#   proxy exposes its loopback-only :2381 metrics port, the loader Job
#   fragments it with ~64MB of throwaway keys (deleted afterwards), and
#   remediation is a real defrag of the cluster datastore. See
#   fleet/live/ and the scenario README. Touches only the spoke -- safe
#   to invoke directly, multiple times, once per spoke cluster if demoing
#   across several spokes. Run ../fleet/hub.sh afterward (once all spokes
#   are done) to confirm the alert(s) reached the hub's Alertmanager, or
#   use ../run.sh which runs both in order for the common single-spoke
#   case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-datastore"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

if [ "${ETCD_LIVE_CLUSTER:-0}" = "1" ]; then
    platform=$(detect_spoke_platform)
    if [ "$platform" != "kind" ]; then
        echo "ERROR: ETCD_LIVE_CLUSTER=1 requires a kind spoke (got: ${platform}) -- the live control-plane etcd is only reachable there. Use the dedicated mode on OCP." >&2
        exit 1
    fi

    echo "==> [spoke=${SPOKE_KUBECONFIG}] LIVE mode: fragmenting the kind control-plane etcd."
    echo "    Writes ~16MB under /demo-frag/ (deleted afterwards); defrag reclaims the space."
    LIVE_DIR="${SCRIPT_DIR}/fleet/live"
    fleet_deploy_workload "${LIVE_DIR}"
    fleet_bootstrap_monitoring "${LIVE_DIR}"

    echo "==> [spoke] Waiting for metrics proxy to be ready..."
    kubectl_workload wait --for=condition=Available deployment/etcd-metrics-proxy \
        -n "${NAMESPACE}" --timeout=180s
    kubectl_workload get pods -n "${NAMESPACE}" -l app=etcd-live-proxy
    echo ""

    echo "==> [spoke] Establishing healthy baseline (defragging live etcd)..."
    kubectl_workload delete job etcd-live-defrag -n "${NAMESPACE}" --ignore-not-found
    kubectl_workload apply -f "${SCRIPT_DIR}/fleet/defrag-job.yaml"
    kubectl_workload wait --for=condition=complete job/etcd-live-defrag \
        -n "${NAMESPACE}" --timeout=600s
    echo ""

    echo "==> [spoke] Fragmenting live etcd (loader Job, ~1 min)..."
    kubectl_workload delete job etcd-frag-loader -n "${NAMESPACE}" --ignore-not-found
    kubectl_workload apply -f "${SCRIPT_DIR}/fleet/loader-job.yaml"
    kubectl_workload wait --for=condition=complete job/etcd-frag-loader \
        -n "${NAMESPACE}" --timeout=900s
    echo ""
    echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
    echo "    Remediate afterwards by re-applying fleet/defrag-job.yaml and watching the alert resolve."
    exit 0
fi

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
if [ "$(detect_spoke_platform)" = "kind" ] && fleet_spoke_is_arm64; then
    echo "ERROR: the dedicated demo etcd image is amd64-only and cannot run on this arm64 spoke." >&2
    echo "  Re-run with ETCD_LIVE_CLUSTER=1 to fragment the kind control-plane etcd instead." >&2
    exit 1
fi
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_bootstrap_monitoring "${MANIFEST_DIR}"

echo "==> [spoke] Waiting for etcd StatefulSet to be ready..."
kubectl_workload rollout status statefulset/etcd -n "${NAMESPACE}" --timeout=600s
echo "  etcd cluster ready."
kubectl_workload get pods -n "${NAMESPACE}" -l app=etcd
echo ""

echo "==> [spoke] Verifying etcd cluster health..."
kubectl_workload exec etcd-0 -n "${NAMESPACE}" -- \
  etcdctl --endpoints=http://localhost:2379 member list --write-out=table
echo ""

echo "==> [spoke] Waiting for Prometheus to scrape etcd metrics (30s)..."
sleep 30

echo "==> [spoke] Injecting etcd fragmentation..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-fragmentation.sh"
echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
