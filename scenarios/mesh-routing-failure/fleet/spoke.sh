#!/usr/bin/env bash
# Istio Mesh Routing Failure Demo -- Fleet Spoke Steps
#
# Deploys the meshed api-server + traffic-gen and injects the deny-all
# AuthorizationPolicy against SPOKE_KUBECONFIG. Requires Istio already
# installed on the spoke (same prerequisite as local mode) -- this script
# does not install it. If missing:
#   istioctl install --set profile=minimal -y --kubeconfig="$SPOKE_KUBECONFIG"
#
# The PodMonitor (prometheus-operator) is skipped on the spoke like every
# other operator-only kind; instead this adds a raw role:pod scrape job
# for the istio-proxy sidecar's Envoy stats port (same target selection as
# the PodMonitor: container name istio-proxy, port name http-envoy-prom),
# with a namespace/pod relabel step prometheus-operator's PodMonitor
# controller would otherwise add automatically.
#
# Touches only the spoke -- safe to invoke directly, multiple times, once
# per spoke cluster if demoing across several spokes. Run ../fleet/hub.sh
# afterward (once all spokes are done) to confirm the alert(s) reached the
# hub's Alertmanager, or use ../run.sh which runs both in order for the
# common single-spoke case.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-mesh"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_spoke_connectivity

if ! kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get deployment istiod -n istio-system &>/dev/null; then
    echo "ERROR: Istio is not installed on the spoke. Run:" >&2
    echo "  istioctl install --set profile=minimal -y --kubeconfig=\"\$SPOKE_KUBECONFIG\"" >&2
    exit 1
fi

echo "==> [spoke=${SPOKE_KUBECONFIG}] Deploying scenario resources..."
MANIFEST_DIR=$(fleet_get_manifest_dir "${SCRIPT_DIR}")
fleet_deploy_workload "${MANIFEST_DIR}"
fleet_ensure_pod_scrape_job "istio-proxy" "${NAMESPACE}" "/stats/prometheus" \
  "  - source_labels: [__meta_kubernetes_pod_container_name]
    regex: istio-proxy
    action: keep
  - source_labels: [__meta_kubernetes_pod_container_port_name]
    regex: http-envoy-prom
    action: keep
  - source_labels: [__meta_kubernetes_namespace]
    target_label: namespace
  - source_labels: [__meta_kubernetes_pod_name]
    target_label: pod"
fleet_load_prometheus_rule "${SCRIPT_DIR}/manifests/prometheus-rule.yaml"
fleet_reload_spoke_prometheus

echo "==> [spoke] Waiting for deployments to be ready (sidecar injection takes a moment)..."
kubectl_workload wait --for=condition=Available deployment/api-server \
  -n "${NAMESPACE}" --timeout=120s
kubectl_workload wait --for=condition=Available deployment/traffic-gen \
  -n "${NAMESPACE}" --timeout=120s
echo "  Workload and traffic generator deployed with Istio sidecars."
kubectl_workload get pods -n "${NAMESPACE}"
echo ""

echo "==> [spoke] Establishing healthy baseline (30s)..."
sleep 30
echo "  Baseline established."
echo ""

echo "==> [spoke] Injecting restrictive AuthorizationPolicy..."
KUBECONFIG="${SPOKE_KUBECONFIG}" bash "${SCRIPT_DIR}/inject-deny-policy.sh"
echo ""
echo "  Waiting for policy to take effect (5s)..."
sleep 5
kubectl_workload get pods -n "${NAMESPACE}"
echo ""
echo "==> [spoke] Fault injected. Run fleet/hub.sh (or ../run.sh) to confirm the alert on the hub."
