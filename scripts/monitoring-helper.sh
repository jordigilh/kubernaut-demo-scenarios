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
                echo "  Install from OperatorHub: OpenShift GitOps operator"
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
        awx-engine)
            require_infra awx
            if ! kubectl get configmap workflowexecution-config -n "${PLATFORM_NS:-kubernaut-system}" \
                -o jsonpath='{.data.workflowexecution\.yaml}' 2>/dev/null | grep -q 'ansible'; then
                echo "ERROR: The WorkflowExecution controller does not have the ansible engine configured."
                echo "  AWX/AAP is installed but the Helm chart was not deployed with ansible engine support."
                echo ""
                echo "  The WE ConfigMap (workflowexecution-config) needs an engines.ansible section"
                echo "  with AWX connection details. Upgrade the Helm release with the appropriate"
                echo "  workflowExecution engine values for your chart version."
                exit 1
            fi
            return 0 ;;
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

# Restart the UWM prometheus-operator so it picks up newly-created
# ServiceMonitors in user namespaces. Works around a known race where the
# operator acknowledges the resource but does not regenerate the Prometheus
# scrape configuration until bounced (#129).
# No-op on Kind (where kube-prometheus-stack handles everything).
refresh_uwm_scrape_config() {
    if [ "${PLATFORM:-}" != "ocp" ]; then
        return 0
    fi

    local ns="openshift-user-workload-monitoring"
    local deploy="prometheus-operator"

    if ! kubectl get deployment "$deploy" -n "$ns" &>/dev/null; then
        echo "  WARNING: $deploy not found in $ns — skipping UWM refresh."
        return 0
    fi

    echo "  Restarting UWM prometheus-operator to pick up new ServiceMonitors (#129)..."
    kubectl rollout restart deployment "$deploy" -n "$ns"
    kubectl rollout status deployment "$deploy" -n "$ns" --timeout=60s 2>/dev/null || \
        echo "  WARNING: $deploy rollout did not complete within 60s."
}

# ── Preflight & Post-deploy Checks ───────────────────────────────────────────
# Shared checks that scenarios call to verify runtime conditions before/after
# deploying resources. These validate that the cluster can actually run the
# scenario (metrics flowing, storage provisioning, alerts cleared, rules loaded).
#
# Usage (pre-deploy):
#   preflight_check metrics-pipeline storage alert-quiescent:demo-ns
#
# Usage (post-deploy, after kubectl apply -k):
#   postdeploy_check istio-scraping prometheusrule:MyAlertName
#
# All checks are read-only and safe to run in parallel across scenarios.
# Mutable resources (test PVCs) use unique names derived from PID + timestamp.

# Resolve the Prometheus pod and namespace for the current platform.
_prom_pod_and_ns() {
    if [ "${PLATFORM:-kind}" = "ocp" ]; then
        echo "openshift-monitoring prometheus-k8s-0"
    else
        echo "monitoring prometheus-kube-prometheus-stack-prometheus-0"
    fi
}

# Resolve the AlertManager pod and namespace for the current platform.
_am_pod_and_ns() {
    if [ "${PLATFORM:-kind}" = "ocp" ]; then
        echo "openshift-monitoring alertmanager-main-0"
    else
        echo "monitoring alertmanager-kube-prometheus-stack-alertmanager-0"
    fi
}

# Query Prometheus via kubectl exec (no port-forward needed, parallel-safe).
# By default queries the platform Prometheus. Pass "uwm" as $2 to query
# the user-workload Prometheus (OCP only; no-op on Kind).
_prom_query() {
    local query="$1"
    local target="${2:-platform}"
    local prom_ns prom_pod
    if [ "$target" = "uwm" ] && [ "${PLATFORM:-kind}" = "ocp" ]; then
        prom_ns="openshift-user-workload-monitoring"
        prom_pod="prometheus-user-workload-0"
    else
        local prom_info
        prom_info=$(_prom_pod_and_ns)
        read -r prom_ns prom_pod <<< "$prom_info"
    fi
    kubectl exec -n "$prom_ns" "$prom_pod" -- \
        curl -sf --connect-timeout 5 \
        "http://localhost:9090/api/v1/query?query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))" 2>/dev/null || echo "$query")" \
        2>/dev/null || echo '{"status":"error"}'
}

# Extract result count from a Prometheus query JSON response.
_prom_result_count() {
    python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(len(d.get('data',{}).get('result',[])))
except:
    print(0)
"
}

# ── metrics-pipeline: kube-state-metrics is scraping ──
_check_metrics_pipeline() {
    if [ "${_PREFLIGHT_METRICS_OK:-}" = "1" ]; then
        echo "  Preflight [metrics-pipeline]: OK (cached)"
        return 0
    fi
    echo "  Preflight [metrics-pipeline]: checking kube-state-metrics..."
    local elapsed=0
    while [ "$elapsed" -lt 30 ]; do
        local count
        count=$(_prom_query 'count(kube_pod_container_status_restarts_total)' | _prom_result_count)
        if [ "$count" -gt 0 ]; then
            echo "  Preflight [metrics-pipeline]: OK ($count series)"
            export _PREFLIGHT_METRICS_OK=1
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo "  ERROR: kube_pod_container_status_restarts_total has 0 series in Prometheus."
    echo "    kube-state-metrics may not be scraping. Check:"
    echo "    kubectl get servicemonitor kube-state-metrics -n ${MONITORING_NS:-openshift-monitoring}"
    return 1
}

# ── storage-provisioning: default StorageClass can bind PVCs ──
_check_storage_provisioning() {
    echo "  Preflight [storage]: testing PVC provisioning..."
    local sc_name
    sc_name=$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | awk '{print $1}')
    if [ -z "$sc_name" ]; then
        echo "  ERROR: No default StorageClass found."
        echo "    kubectl get storageclass"
        return 1
    fi

    local pvc_name="preflight-pvc-$$-$(date +%s)"
    kubectl apply -f - <<PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${sc_name}
  resources:
    requests:
      storage: 1Mi
PVC

    # WaitForFirstConsumer StorageClasses won't bind until a pod mounts the PVC,
    # so we create a tiny pod to trigger binding.
    local binding_mode
    binding_mode=$(kubectl get storageclass "$sc_name" -o jsonpath='{.volumeBindingMode}' 2>/dev/null)
    local pod_name=""
    if [ "$binding_mode" = "WaitForFirstConsumer" ]; then
        pod_name="preflight-bind-$$-$(date +%s)"
        kubectl run "$pod_name" -n default --image=busybox --restart=Never \
            --overrides="{\"spec\":{\"containers\":[{\"name\":\"bind\",\"image\":\"busybox\",\"command\":[\"sleep\",\"5\"],\"volumeMounts\":[{\"name\":\"data\",\"mountPath\":\"/data\"}]}],\"volumes\":[{\"name\":\"data\",\"persistentVolumeClaim\":{\"claimName\":\"${pvc_name}\"}}]}}" \
            2>/dev/null || true
    fi

    local elapsed=0
    local bound=false
    while [ "$elapsed" -lt 60 ]; do
        local phase
        phase=$(kubectl get pvc "$pvc_name" -n default -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$phase" = "Bound" ]; then
            bound=true
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    # Cleanup (parallel-safe: unique names)
    kubectl delete pvc "$pvc_name" -n default --ignore-not-found --wait=false 2>/dev/null || true
    [ -n "$pod_name" ] && kubectl delete pod "$pod_name" -n default --ignore-not-found --force --grace-period=0 2>/dev/null || true

    if [ "$bound" = true ]; then
        echo "  Preflight [storage]: OK (${sc_name}, bound in ${elapsed}s)"
        return 0
    else
        echo "  ERROR: Test PVC did not bind within 60s (StorageClass: ${sc_name}, binding: ${binding_mode:-Immediate})."
        echo "    The cluster may not have enough storage capacity."
        echo "    Check: kubectl get pv; kubectl describe pvc ${pvc_name} -n default"
        return 1
    fi
}

# ── alert-quiescent: no stale alerts for a namespace ──
_check_alert_quiescent() {
    local namespace="$1"
    echo "  Preflight [alert-quiescent]: checking for stale alerts in ${namespace}..."
    local am_info am_ns am_pod
    am_info=$(_am_pod_and_ns)
    read -r am_ns am_pod <<< "$am_info"

    local elapsed=0
    while [ "$elapsed" -lt 60 ]; do
        local count
        count=$(kubectl exec -n "$am_ns" "$am_pod" -- \
            amtool alert query "namespace=${namespace}" \
            --alertmanager.url=http://localhost:9093 \
            --output=json 2>/dev/null \
            | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
        if [ "$count" = "0" ]; then
            echo "  Preflight [alert-quiescent]: OK (no active alerts in ${namespace})"
            return 0
        fi
        if [ "$elapsed" = "0" ]; then
            echo "  Preflight [alert-quiescent]: ${count} stale alert(s) in ${namespace}, waiting to clear..."
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    echo "  ERROR: ${count} stale alert(s) still active in namespace ${namespace} after 60s."
    echo "    Previous scenario cleanup may be incomplete. Check:"
    echo "    kubectl exec -n ${am_ns} ${am_pod} -- amtool alert query namespace=${namespace} --alertmanager.url=http://localhost:9093"
    return 1
}

# ── istio-scraping: Istio sidecar metrics are being ingested ──
_check_istio_scraping() {
    echo "  Postdeploy [istio-scraping]: waiting for istio_requests_total in Prometheus..."
    # On OCP, Istio ServiceMonitors are in user namespaces → UWM Prometheus.
    local prom_target="platform"
    [ "${PLATFORM:-kind}" = "ocp" ] && prom_target="uwm"
    local elapsed=0
    while [ "$elapsed" -lt 120 ]; do
        local count
        count=$(_prom_query 'count(istio_requests_total)' "$prom_target" | _prom_result_count)
        if [ "$count" -gt 0 ]; then
            echo "  Postdeploy [istio-scraping]: OK ($count series)"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    echo "  ERROR: istio_requests_total has 0 series after 120s."
    echo "    Istio sidecar metrics are not being scraped by Prometheus."
    echo "    On OCP, verify:"
    echo "      1. User Workload Monitoring is enabled (openshift-user-workload-monitoring namespace exists)"
    echo "      2. ServiceMonitor istio-proxy exists: kubectl get servicemonitor -A | grep istio"
    echo "      3. Envoy stats port is correct (15090 for OSSM 3 native sidecars)"
    echo "      4. UWM prometheus-operator was restarted after ServiceMonitor creation"
    return 1
}

# ── prometheusrule-loaded: verify a specific alert rule is loaded in Prometheus ──
# Checks both platform and UWM Prometheus on OCP.
_check_rule_loaded() {
    local alert_name="$1"
    echo "  Postdeploy [prometheusrule:${alert_name}]: verifying rule is loaded..."

    local elapsed=0
    while [ "$elapsed" -lt 60 ]; do
        local found="missing"
        # Check platform Prometheus
        local prom_info prom_ns prom_pod
        prom_info=$(_prom_pod_and_ns)
        read -r prom_ns prom_pod <<< "$prom_info"
        found=$(_query_rules_for_alert "$prom_ns" "$prom_pod" "$alert_name")
        # On OCP, also check UWM Prometheus
        if [ "$found" != "found" ] && [ "${PLATFORM:-kind}" = "ocp" ]; then
            found=$(_query_rules_for_alert "openshift-user-workload-monitoring" "prometheus-user-workload-0" "$alert_name")
        fi
        if [ "$found" = "found" ]; then
            echo "  Postdeploy [prometheusrule:${alert_name}]: OK (rule loaded)"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo "  ERROR: Alert rule '${alert_name}' not found in Prometheus after 60s."
    echo "    The PrometheusRule may not have been picked up. Check:"
    echo "      kubectl get prometheusrule -A | grep -i ${alert_name}"
    echo "    On OCP, ensure the rule is in a namespace with openshift.io/cluster-monitoring=true"
    return 1
}

_query_rules_for_alert() {
    local ns="$1" pod="$2" alert_name="$3"
    kubectl exec -n "$ns" "$pod" -- \
        curl -sf --connect-timeout 5 'http://localhost:9090/api/v1/rules?type=alert' 2>/dev/null \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
for g in data.get('data',{}).get('groups',[]):
    for r in g.get('rules',[]):
        if r.get('name') == '${alert_name}':
            print('found')
            sys.exit(0)
print('missing')
" 2>/dev/null || echo "error"
}

# ── preflight_check: run pre-deploy capability checks ──
preflight_check() {
    local fail=false
    echo "==> Preflight checks..."
    for cap in "$@"; do
        case "$cap" in
            metrics-pipeline)  _check_metrics_pipeline || fail=true ;;
            storage)           _check_storage_provisioning || fail=true ;;
            alert-quiescent:*) _check_alert_quiescent "${cap#*:}" || fail=true ;;
            *) echo "  WARNING: unknown preflight capability: $cap" ;;
        esac
    done
    if [ "$fail" = true ]; then
        echo ""
        echo "  Preflight FAILED: fix the above issues before running this scenario."
        exit 1
    fi
    echo "==> Preflight passed."
    echo ""
}

# ── postdeploy_check: run post-deploy capability checks ──
postdeploy_check() {
    local fail=false
    for cap in "$@"; do
        case "$cap" in
            istio-scraping)   _check_istio_scraping || fail=true ;;
            prometheusrule:*) _check_rule_loaded "${cap#*:}" || fail=true ;;
            *) echo "  WARNING: unknown postdeploy capability: $cap" ;;
        esac
    done
    if [ "$fail" = true ]; then
        echo ""
        echo "  Postdeploy check FAILED: scenario infrastructure is not ready."
        return 1
    fi
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
# Used by: cert-failure
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
