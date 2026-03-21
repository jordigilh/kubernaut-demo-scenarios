#!/usr/bin/env bash
# Shared monitoring-stack helpers for demo scenarios.
# Source this from run.sh:
#   source "$(dirname "$0")/../../scripts/monitoring-helper.sh"

MONITORING_NS="${MONITORING_NS:-monitoring}"
DEMO_HELM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helm" && pwd)"

# Validate that an infrastructure component is present (no installs).
# Usage: require_infra cert-manager
require_infra() {
    local component="$1"
    case "$component" in
        cert-manager)
            helm status cert-manager -n cert-manager &>/dev/null && return 0
            kubectl get deployment -n cert-manager -l app.kubernetes.io/name=cert-manager --no-headers 2>/dev/null | grep -q . && return 0
            echo "ERROR: cert-manager is not installed. Run: bash scripts/setup-demo-cluster.sh"
            exit 1 ;;
        metrics-server)
            kubectl get deployment metrics-server -n kube-system &>/dev/null && return 0
            kubectl get apiservice v1beta1.metrics.k8s.io &>/dev/null && return 0
            echo "ERROR: metrics-server is not installed. Run: bash scripts/setup-demo-cluster.sh"
            exit 1 ;;
        blackbox)
            helm status prometheus-blackbox-exporter -n "${MONITORING_NS}" &>/dev/null && return 0
            echo "ERROR: blackbox-exporter is not installed. Run: bash scripts/setup-demo-cluster.sh"
            exit 1 ;;
        gitea)
            kubectl get namespace gitea &>/dev/null && return 0
            echo "ERROR: Gitea is not installed. Run: bash scripts/setup-demo-cluster.sh"
            exit 1 ;;
        argocd)
            if [ "${PLATFORM:-}" = "ocp" ]; then
                kubectl get namespace openshift-gitops &>/dev/null && return 0
                echo "ERROR: OpenShift GitOps is not installed."
                echo "  Install via: oc apply -f operators/openshift-gitops-subscription.yaml"
            else
                kubectl get namespace argocd &>/dev/null && return 0
                echo "ERROR: ArgoCD is not installed. Run: bash scripts/setup-demo-cluster.sh"
            fi
            exit 1 ;;
        istio)
            if [ "${PLATFORM:-}" = "ocp" ]; then
                kubectl get namespace istio-system &>/dev/null && return 0
                echo "ERROR: OpenShift Service Mesh is not installed."
                echo "  Install via the OSSM operator in OperatorHub."
            else
                kubectl get namespace istio-system &>/dev/null && return 0
                echo "ERROR: Istio is not installed. Run: istioctl install --set profile=demo"
            fi
            exit 1 ;;
        awx)
            kubectl get deployment -n kubernaut-system -l app.kubernetes.io/managed-by=awx-operator --no-headers 2>/dev/null | grep -q . && return 0
            kubectl get automationcontroller -A --no-headers 2>/dev/null | grep -q . && return 0
            echo "ERROR: AWX/AAP is not installed. Run: bash scripts/awx-helper.sh"
            exit 1 ;;
        *)
            echo "ERROR: Unknown infrastructure component: ${component}"
            exit 1 ;;
    esac
}

# ── OCP User Workload Monitoring ─────────────────────────────────────────────
# Required on OCP for scraping PodMonitors/ServiceMonitors in user namespaces.
# Used by: mesh-routing-failure (Istio sidecar metrics via PodMonitor)
ensure_user_workload_monitoring() {
    if [ "${PLATFORM:-}" != "ocp" ]; then
        return 0
    fi

    if kubectl get namespace openshift-user-workload-monitoring &>/dev/null &&
       kubectl get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | grep -q Running; then
        echo "  OCP user-workload monitoring already enabled."
        return 0
    fi

    echo "==> Enabling OCP user-workload monitoring..."
    kubectl apply -f - <<'UWM'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
UWM

    echo "  Waiting for user-workload monitoring pods (up to 120s)..."
    local elapsed=0
    while [ "$elapsed" -lt 120 ]; do
        if kubectl get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | grep -q Running; then
            echo "  OCP user-workload monitoring enabled."
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    echo "  WARNING: user-workload monitoring pods not yet Running after 120s."
    echo "  The scenario may still work via cluster-monitoring with openshift.io/cluster-monitoring label."
}

# ── kube-prometheus-stack ────────────────────────────────────────────────────
# Installs kube-prometheus-stack via Helm (idempotent).
# Provides: Prometheus Operator, Prometheus, AlertManager, Grafana,
#           kube-state-metrics, node-exporter.
ensure_monitoring_stack() {
    if helm status kube-prometheus-stack -n "${MONITORING_NS}" &>/dev/null; then
        echo "  kube-prometheus-stack already installed."
        return 0
    fi

    echo "==> Installing kube-prometheus-stack..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update prometheus-community

    kubectl create namespace "${MONITORING_NS}" --dry-run=client -o yaml | kubectl apply -f -

    local prom_args=(
        --namespace "${MONITORING_NS}"
        --values "${DEMO_HELM_DIR}/kube-prometheus-stack-values.yaml"
    )
    if [ "${PLATFORM:-kind}" = "ocp" ] && [ -f "${DEMO_HELM_DIR}/kube-prometheus-stack-ocp-overrides.yaml" ]; then
        prom_args+=(--values "${DEMO_HELM_DIR}/kube-prometheus-stack-ocp-overrides.yaml")
    fi
    prom_args+=(--wait --timeout 5m)

    helm upgrade --install kube-prometheus-stack \
        prometheus-community/kube-prometheus-stack \
        "${prom_args[@]}"

    echo "  kube-prometheus-stack installed in ${MONITORING_NS}."

    ensure_grafana_dashboard
}

# ── Grafana dashboard ConfigMap ──────────────────────────────────────────────
# Applies the Kubernaut Operations dashboard ConfigMap with the
# grafana_dashboard label so the Grafana sidecar autodiscovers it.
ensure_grafana_dashboard() {
    local dashboard_cm="${DEMO_HELM_DIR}/grafana-dashboard-kubernaut.yaml"

    if [ -f "$dashboard_cm" ]; then
        kubectl apply -f "$dashboard_cm" -n "${MONITORING_NS}"
        echo "  Kubernaut operations dashboard provisioned."
    fi
}

# ── cert-manager ─────────────────────────────────────────────────────────────
# Used by: cert-failure, cert-failure-gitops
ensure_cert_manager() {
    if helm status cert-manager -n cert-manager &>/dev/null; then
        echo "  cert-manager already installed."
        return 0
    fi

    echo "==> Installing cert-manager..."
    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo update jetstack

    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --set crds.enabled=true \
        --set prometheus.enabled=true \
        --wait --timeout 3m

    echo "  cert-manager installed."
}

# ── metrics-server ───────────────────────────────────────────────────────────
# Used by: hpa-maxed, autoscale (HPA requires real CPU/memory metrics)
ensure_metrics_server() {
    if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
        echo "  metrics-server already installed."
        return 0
    fi
    if kubectl get apiservice v1beta1.metrics.k8s.io &>/dev/null; then
        echo "  metrics-server provided by platform (OCP)."
        return 0
    fi

    echo "==> Installing metrics-server..."
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
    helm repo update metrics-server

    helm upgrade --install metrics-server metrics-server/metrics-server \
        --namespace kube-system \
        --set args='{--kubelet-insecure-tls}' \
        --wait --timeout 3m

    echo "  metrics-server installed."
}

# ── Istio ────────────────────────────────────────────────────────────────────
# Used by: mesh-routing-failure
ensure_istio() {
    if kubectl get namespace istio-system &>/dev/null; then
        echo "  Istio already installed."
        return 0
    fi

    echo "==> Installing Istio..."

    if ! command -v istioctl &>/dev/null; then
        echo "ERROR: istioctl not found in PATH."
        echo "  Install: curl -L https://istio.io/downloadIstio | sh -"
        echo "  Then: export PATH=\$PWD/istio-*/bin:\$PATH"
        exit 1
    fi

    istioctl install --set profile=demo -y
    kubectl wait --for=condition=Available deployment/istiod \
      -n istio-system --timeout=300s

    echo "  Istio installed."
}

# ── Blackbox Exporter ────────────────────────────────────────────────────────
# Used by: slo-burn (probe_success metric)
ensure_blackbox_exporter() {
    if helm status prometheus-blackbox-exporter -n "${MONITORING_NS}" &>/dev/null; then
        echo "  blackbox-exporter already installed."
        return 0
    fi

    echo "==> Installing blackbox-exporter..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true

    helm upgrade --install prometheus-blackbox-exporter \
        prometheus-community/prometheus-blackbox-exporter \
        --namespace "${MONITORING_NS}" \
        --wait --timeout 2m

    echo "  blackbox-exporter installed."
}
