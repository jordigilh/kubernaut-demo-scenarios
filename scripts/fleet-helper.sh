#!/usr/bin/env bash
# Fleet-mode helpers for demo scenario run.sh scripts.
# Source this from run.sh:
#   source "$(dirname "$0")/../../scripts/fleet-helper.sh"
#
# Fleet mode: hub cluster runs the Kubernaut control plane (catalog CRs,
# APIFrontend, Console, etc.); a separate spoke cluster runs the demo
# workload and is investigated/remediated remotely via the fleet MCP
# gateway. The spoke runs an operator-managed Prometheus instance
# (Prometheus/fleet-spoke, all selectors open), so scenario monitoring
# CRDs (ServiceMonitor/PodMonitor/Probe/PrometheusRule) are applied to the
# spoke natively -- the same production-shaped resources used by OCP and
# single-cluster mode. No raw prometheus-config surgery, no rule-file
# translation, no Prometheus restarts: the operator picks up CRD changes
# on its own.
#
# Fleet mode is opt-in: explicit at the CLI via --fleet (see
# fleet_dispatch_requested below), validated against two env vars; every
# function below is a no-op (or must not be called) when they are unset, so
# single-cluster scenarios are unaffected.
#
#   HUB_KUBECONFIG    kubeconfig for the cluster running the Kubernaut
#                      control plane
#   SPOKE_KUBECONFIG   kubeconfig for the cluster running the demo workload

is_fleet_mode() {
    [ -n "${HUB_KUBECONFIG:-}" ] && [ -n "${SPOKE_KUBECONFIG:-}" ]
}

# Dispatch-decision gate for each scenario's top-level run.sh: fleet mode
# only activates when --fleet is explicitly passed, never implicitly from
# stray env vars left over from a previous fleet session (a real footgun --
# a plain, no-args invocation would otherwise silently run against a remote
# spoke instead of locally). Hard error if --fleet is passed without both
# kubeconfig env vars set (fail loud, not a silent fallback to local mode);
# returns 1 with no error if --fleet is absent, even when both env vars
# happen to be set, so is_fleet_mode()'s own env-var-only check (still used
# internally by kubectl_workload et al. once fleet mode is confirmed active)
# never gets reached from a plain invocation.
#
# Call as: if fleet_dispatch_requested "$@"; then ... fi
fleet_dispatch_requested() {
    local _arg _requested=""
    for _arg in "$@"; do
        if [ "$_arg" = "--fleet" ]; then
            _requested=1
            break
        fi
    done
    [ -n "$_requested" ] || return 1

    local _missing=()
    [ -z "${HUB_KUBECONFIG:-}" ] && _missing+=("HUB_KUBECONFIG")
    [ -z "${SPOKE_KUBECONFIG:-}" ] && _missing+=("SPOKE_KUBECONFIG")
    if [ "${#_missing[@]}" -gt 0 ]; then
        echo "ERROR: --fleet requires ${_missing[*]} to be set (missing: ${_missing[*]})." >&2
        exit 1
    fi
    return 0
}

# Explicit-unsupported gate for scenarios WITHOUT fleet mode: call with the
# scenario name and the script's "$@" right after SCRIPT_DIR is set. Fails
# loud if --fleet was passed (fleet mode is never a silent no-op or a quiet
# local fallback), returns 0 otherwise. Fleet-capable scenarios use
# fleet_dispatch_requested instead, which dispatches to fleet/run.sh.
#
# Call as: fleet_fail_if_requested "<scenario-name>" "$@"
fleet_fail_if_requested() {
    local scenario="${1:?usage: fleet_fail_if_requested <scenario-name> -- <args...>}"
    shift
    local _arg
    for _arg in "$@"; do
        if [ "$_arg" = "--fleet" ]; then
            echo "ERROR: scenario '${scenario}' does not support --fleet (no fleet mode; see the Fleet column in docs/scenarios.md)." >&2
            exit 1
        fi
    done
}

# One scenario's fleet/hub.sh stays alert-only for scenario-specific
# reasons unrelated to fleet mode in general (see its call site) -- there's
# no single-cluster AF/A2A pipeline to run against a remote spoke for it,
# so flags that steer it (--interactive/--auto-approve/--no-validate) have
# nothing to attach to. Warn once so that's not surprising to someone
# passing them out of habit; call from that scenario's top-level run.sh
# right before dispatching to fleet/run.sh. Every other fleet-aware
# scenario's hub.sh now parses and acts on these flags itself (via
# fleet_drive_pipeline below), so they don't call this anymore -- --fleet
# itself is never reported as "ignored" here since it's the dispatch
# selector, always consumed by definition.
fleet_warn_ignored_args() {
    local _ignored=() _arg
    for _arg in "$@"; do
        [ "$_arg" = "--fleet" ] || _ignored+=("$_arg")
    done
    if [ "${#_ignored[@]}" -gt 0 ]; then
        echo "NOTE: this scenario's fleet mode stays alert-only (see fleet/hub.sh for why); ignoring CLI arg(s): ${_ignored[*]}" >&2
    fi
}

_fleet_require_mode() {
    if ! is_fleet_mode; then
        echo "ERROR: $1 requires HUB_KUBECONFIG and SPOKE_KUBECONFIG to be set." >&2
        return 1
    fi
}

FLEET_MONITORING_NS="${FLEET_MONITORING_NS:-monitoring}"

# Operator-managed monitoring kinds a scenario may ship. fleet_deploy_workload
# skips these (they go through fleet_deploy_monitoring instead, keeping
# workload deployment separate from monitoring resource deployment);
# fleet_deploy_monitoring applies ONLY these.

# Run a kubectl command against the workload cluster: the spoke in fleet
# mode, the ambient KUBECONFIG otherwise. Scenario fleet/run.sh scripts use
# this for every command that targets the demo workload namespace (as
# opposed to the Kubernaut control plane, which stays on the ambient/hub
# context).
kubectl_workload() {
    if is_fleet_mode; then
        kubectl --kubeconfig="${SPOKE_KUBECONFIG}" "$@"
    else
        kubectl "$@"
    fi
}

# Detect whether the spoke is OpenShift or vanilla Kubernetes. Mirrors
# platform-helper.sh's detect_platform(), but scoped to SPOKE_KUBECONFIG --
# the hub and spoke can run different platforms, and the ambient PLATFORM
# env var (if set) reflects the hub's context, not the spoke's. Override
# with SPOKE_PLATFORM=ocp|kind to skip detection.
detect_spoke_platform() {
    _fleet_require_mode "detect_spoke_platform" || return 1
    if [ -n "${SPOKE_PLATFORM:-}" ]; then
        echo "${SPOKE_PLATFORM}"
        return 0
    fi
    local api_output
    api_output=$(kubectl --kubeconfig="${SPOKE_KUBECONFIG}" api-resources \
        --api-group=config.openshift.io 2>/dev/null) || true
    if echo "$api_output" | grep -q ClusterVersion; then
        echo "ocp"
    else
        echo "kind"
    fi
}

# Returns the kustomize directory to deploy to the spoke: the OCP overlay
# when the spoke is OpenShift and one exists, otherwise the base manifests.
# Same selection rule as platform-helper.sh's get_manifest_dir(), but keyed
# off the spoke's platform instead of the ambient one -- use this from
# fleet/run.sh instead of hardcoding "${SCRIPT_DIR}/manifests".
fleet_get_manifest_dir() {
    local scenario_dir="${1:?usage: fleet_get_manifest_dir <scenario-dir>}"
    local platform
    platform=$(detect_spoke_platform)
    if [ "$platform" = "ocp" ] && [ -d "${scenario_dir}/overlays/ocp" ]; then
        echo "${scenario_dir}/overlays/ocp"
    else
        echo "${scenario_dir}/manifests"
    fi
}

# Verify only the hub is reachable. Call from a scenario's fleet/hub.sh,
# which touches nothing else.
fleet_check_hub_connectivity() {
    _fleet_require_mode "fleet_check_hub_connectivity" || return 1
    if ! kubectl --kubeconfig="${HUB_KUBECONFIG}" cluster-info &>/dev/null; then
        echo "ERROR: Cannot connect to hub cluster (HUB_KUBECONFIG)." >&2
        return 1
    fi
}

# Verify only the spoke is reachable. Call from a scenario's fleet/spoke.sh,
# which touches nothing else -- this is deliberately independent of hub
# connectivity so spoke.sh stays invocable on its own (e.g. once per spoke,
# for multi-spoke demos of the same fault).
fleet_check_spoke_connectivity() {
    _fleet_require_mode "fleet_check_spoke_connectivity" || return 1
    if ! kubectl --kubeconfig="${SPOKE_KUBECONFIG}" cluster-info &>/dev/null; then
        echo "ERROR: Cannot connect to spoke cluster (SPOKE_KUBECONFIG)." >&2
        return 1
    fi
}

# Verify both clusters are reachable. Convenience wrapper for callers that
# want a single up-front check (e.g. before running spoke.sh then hub.sh
# back-to-back for the single-spoke case).
fleet_check_connectivity() {
    fleet_check_hub_connectivity && fleet_check_spoke_connectivity
}

# Deploy scenario workload resources (namespace/configmap/deployment) to the
# spoke cluster. Deliberately skips any PrometheusRule/ServiceMonitor/Probe/
# PodMonitor/ScrapeConfig documents in the manifest dir -- those go through
# fleet_deploy_monitoring instead, keeping workload deployment separate from
# monitoring resource deployment.
#
# Args: $1 = manifest dir (e.g. scenarios/crashloop/manifests)
fleet_deploy_workload() {
    _fleet_require_mode "fleet_deploy_workload" || return 1
    local manifest_dir="${1:?usage: fleet_deploy_workload <manifest-dir>}"

    echo "==> [fleet] Deploying workload manifests to spoke (skipping operator monitoring kinds -- see fleet_deploy_monitoring)..."
    local tmpdir
    tmpdir=$(mktemp -d)
    # Double quotes: expand now so the trap holds the literal path -- a
    # single-quoted '${tmpdir}' would evaluate at RETURN time, when the
    # local is already out of scope under `set -u`.
    trap "rm -rf '${tmpdir}'" RETURN

    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" kustomize "${manifest_dir}" > "${tmpdir}/rendered.yaml"

    python3 -c "
import sys, os
d, n, f = sys.argv[1], 0, None
for line in open(sys.argv[2]):
    if line.strip() == '---':
        n += 1; f = None; continue
    if f is None: f = open(os.path.join(d, f'doc-{n}.yaml'), 'a')
    f.write(line)
" "${tmpdir}" "${tmpdir}/rendered.yaml"

    local applied=0 skipped=0
    for doc in "${tmpdir}"/doc-*.yaml; do
        [ -f "$doc" ] || continue
        if grep -qE 'kind: (PrometheusRule|ServiceMonitor|Probe|PodMonitor|ScrapeConfig)' "$doc"; then
            skipped=$((skipped + 1))
            continue
        fi
        kubectl --kubeconfig="${SPOKE_KUBECONFIG}" apply -f "$doc" 2>&1 | sed 's/^/    /'
        applied=$((applied + 1))
    done
    echo "  Applied ${applied} document(s) to spoke, skipped ${skipped} (monitoring kinds)."
}

# Deploy a scenario's operator monitoring resources (ServiceMonitor,
# PodMonitor, Probe, PrometheusRule, ScrapeConfig) to the spoke cluster.
# Applies ONLY those kinds -- the workload half goes through
# fleet_deploy_workload. Platform-aware: pass the fleet_get_manifest_dir
# selection (Kind base vs OCP overlay) so overlays that swap monitoring
# shapes (e.g. mesh-routing-failure's PodMonitor<->ServiceMonitor swap)
# keep working. Never mutates prometheus-config and never restarts
# Prometheus: the operator reconciles CRD changes on its own.
#
# Args: $1 = manifest dir (e.g. scenarios/crashloop/manifests)
fleet_deploy_monitoring() {
    _fleet_require_mode "fleet_deploy_monitoring" || return 1
    local manifest_dir="${1:?usage: fleet_deploy_monitoring <manifest-dir>}"

    echo "==> [fleet] Deploying monitoring CRDs to spoke (operator-native, no config surgery)..."
    local tmpdir
    tmpdir=$(mktemp -d)
    # Double quotes: expand now so the trap holds the literal path -- a
    # single-quoted '${tmpdir}' would evaluate at RETURN time, when the
    # local is already out of scope under `set -u`.
    trap "rm -rf '${tmpdir}'" RETURN

    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" kustomize "${manifest_dir}" > "${tmpdir}/rendered.yaml"

    python3 -c "
import sys, os
d, n, f = sys.argv[1], 0, None
for line in open(sys.argv[2]):
    if line.strip() == '---':
        n += 1; f = None; continue
    if f is None: f = open(os.path.join(d, f'doc-{n}.yaml'), 'a')
    f.write(line)
" "${tmpdir}" "${tmpdir}/rendered.yaml"

    local applied=0 skipped=0
    for doc in "${tmpdir}"/doc-*.yaml; do
        [ -f "$doc" ] || continue
        if grep -qE 'kind: (PrometheusRule|ServiceMonitor|Probe|PodMonitor|ScrapeConfig)' "$doc"; then
            kubectl --kubeconfig="${SPOKE_KUBECONFIG}" apply -f "$doc" 2>&1 | sed 's/^/    /'
            applied=$((applied + 1))
        else
            skipped=$((skipped + 1))
        fi
    done
    if [ "$applied" -eq 0 ]; then
        echo "  WARNING: no monitoring CRDs found under ${manifest_dir}; nothing deployed." >&2
    else
        echo "  Applied ${applied} monitoring document(s) to spoke, skipped ${skipped} (workload kinds)."
    fi
}

# Ensure kube-state-metrics is deployed on the spoke's monitoring namespace.
# Idempotent: no-op if the Deployment already exists.
#
# NOTE: on current fleet spokes KSM is owned by the upstream fleet infra
# (jordigilh/kubernaut#2380 tracks two requirements there: honorLabels=true
# on its ServiceMonitor so kube_* series keep their native namespace/pod
# labels, and --resources covering horizontalpodautoscalers,
# persistentvolumeclaims and poddisruptionbudgets). This helper only fills
# the gap when KSM is entirely absent; the RBAC/--resources below are kept
# in parity with the upstream requirement.
#
# The RBAC rules and --resources flag below must cover every kube_*
# resource kind any scenario's PrometheusRule keys off of, or that rule can
# never fire on the spoke (found live, 2026-09-01: hpa-maxed's
# kube_horizontalpodautoscaler_* was silently missing). Cross-check with:
#   grep -ohE 'kube_[a-z_]+' scenarios/*/manifests/prometheus-rule.yaml | sort -u
# when adding a new scenario that depends on a kube-state-metrics series.
fleet_ensure_kube_state_metrics() {
    _fleet_require_mode "fleet_ensure_kube_state_metrics" || return 1

    if kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get deployment kube-state-metrics \
        -n "${FLEET_MONITORING_NS}" &>/dev/null; then
        echo "  [fleet] kube-state-metrics already deployed on spoke."
        return 0
    fi

    echo "==> [fleet] Deploying kube-state-metrics to spoke (${FLEET_MONITORING_NS})..."
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" apply -f - <<'EOF' 2>&1 | sed 's/^/    /'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-state-metrics
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-state-metrics
rules:
- apiGroups: [""]
  resources: ["pods", "nodes", "namespaces", "persistentvolumeclaims"]
  verbs: ["list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
  verbs: ["list", "watch"]
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["list", "watch"]
- apiGroups: ["policy"]
  resources: ["poddisruptionbudgets"]
  verbs: ["list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-state-metrics
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-state-metrics
subjects:
- kind: ServiceAccount
  name: kube-state-metrics
  namespace: monitoring
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-state-metrics
  namespace: monitoring
  labels:
    app: kube-state-metrics
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kube-state-metrics
  template:
    metadata:
      labels:
        app: kube-state-metrics
    spec:
      serviceAccountName: kube-state-metrics
      containers:
      - name: kube-state-metrics
        image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0
        args:
        - --resources=pods,deployments,replicasets,statefulsets,daemonsets,nodes,horizontalpodautoscalers,persistentvolumeclaims,poddisruptionbudgets
        ports:
        - containerPort: 8080
          name: http-metrics
        - containerPort: 8081
          name: telemetry
        resources:
          requests:
            memory: 64Mi
            cpu: 50m
          limits:
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: kube-state-metrics
  namespace: monitoring
  labels:
    app: kube-state-metrics
spec:
  selector:
    app: kube-state-metrics
  ports:
  - name: http-metrics
    port: 8080
    targetPort: 8080
EOF
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" rollout status deployment/kube-state-metrics \
        -n "${FLEET_MONITORING_NS}" --timeout=60s | sed 's/^/    /'
}

# Raw-Prometheus helpers removed (issue #432): the spoke runs an
# operator-managed Prometheus, so fleet_load_prometheus_rule,
# _fleet_ensure_prometheus_config_has, fleet_ensure_scrape_job,
# fleet_ensure_kubelet_metrics_job, fleet_ensure_pod_scrape_job and
# fleet_reload_spoke_prometheus no longer exist. Use fleet_deploy_monitoring
# to apply the scenario's ServiceMonitor/PodMonitor/Probe/PrometheusRule
# CRDs natively -- no prometheus-config mutation, no restarts.

# Poll the hub's Alertmanager for a firing alert, bypassing
# validation-helper.sh's wait_for_alert (which assumes the kube-prometheus-stack
# StatefulSet naming convention -- alertmanager-kube-prometheus-stack-alertmanager-0
# -- that the fleet-e2e raw-manifest hub does not use). Queries the v2 HTTP API
# directly instead of amtool.
#
# Args: $1 = alertname, $2 = namespace label to match, $3 = timeout in seconds (default 300)
fleet_wait_for_alert() {
    _fleet_require_mode "fleet_wait_for_alert" || return 1
    local alertname="${1:?usage: fleet_wait_for_alert <alertname> <namespace> [timeout] [cluster]}"
    local namespace="${2:?usage: fleet_wait_for_alert <alertname> <namespace> [timeout] [cluster]}"
    local timeout="${3:-300}"
    # The spoke's operator-managed Prometheus stamps every alert with the
    # external cluster label (cluster=remote-cluster by default). Use it by
    # default so an unlabeled twin cannot satisfy the wait condition.
    # Override this for multi-spoke demos by passing the fourth argument or
    # setting SPOKE_CLUSTER_LABEL.
    local cluster="${4:-${SPOKE_CLUSTER_LABEL:-remote-cluster}}"

    local ham_pod
    ham_pod=$(kubectl --kubeconfig="${HUB_KUBECONFIG}" get pods -n "${FLEET_MONITORING_NS}" \
        -l app=alertmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "$ham_pod" ]; then
        echo "  WARNING: no alertmanager pod found on hub (namespace ${FLEET_MONITORING_NS})."
        return 1
    fi

    local desc="alert '${alertname}' (namespace=${namespace}${cluster:+, cluster=${cluster}})"
    echo "==> [fleet] Waiting for ${desc} on hub Alertmanager (timeout ${timeout}s)..."
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if kubectl --kubeconfig="${HUB_KUBECONFIG}" exec -n "${FLEET_MONITORING_NS}" "$ham_pod" -- \
            wget -qO- http://localhost:9093/api/v2/alerts 2>/dev/null \
            | python3 -c "
import json, sys
alerts = json.load(sys.stdin)
cluster_filter = '${cluster}'
for a in alerts:
    labels = a.get('labels', {})
    if labels.get('alertname') != '${alertname}' or labels.get('namespace') != '${namespace}':
        continue
    if cluster_filter and labels.get('cluster') != cluster_filter:
        continue
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
            echo "  ${desc} is firing."
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo "  WARNING: ${desc} did not fire within ${timeout}s."
    return 1
}

# Drive the full remediation pipeline on the hub after fleet_wait_for_alert
# has confirmed the scenario's alert firing: waits for Gateway to create the
# RemediationRequest, then polls it through to a terminal phase (handling
# the RemediationApprovalRequest gate per approve_mode). Mirrors local
# mode's own validate.sh (wait_for_rr + poll_pipeline from
# validation-helper.sh), just pointed at HUB_KUBECONFIG instead of the
# ambient/single-cluster context -- PLATFORM_NS (kubernaut-system) lives on
# the hub in fleet mode, and both functions are pure `kubectl` against it
# (no kubectl_workload calls), so they work unmodified once KUBECONFIG is
# switched. Call from a scenario's fleet/hub.sh once the alert is
# confirmed firing, unless --alert-only was requested.
#
# Args: $1 = namespace (the signal's target namespace, used by
#       validation-helper.sh to match the RR), $2 = approve_mode
#       (--interactive|--auto-approve), $3 = optional poll_pipeline timeout
#       in seconds (default 600, matches validate.sh's own default).
fleet_drive_pipeline() {
    _fleet_require_mode "fleet_drive_pipeline" || return 1
    local namespace="${1:?usage: fleet_drive_pipeline <namespace> <approve_mode> [timeout]}"
    local approve_mode="${2:?usage: fleet_drive_pipeline <namespace> <approve_mode> [timeout]}"
    local timeout="${3:-600}"

    export KUBECONFIG="${HUB_KUBECONFIG}"
    # shellcheck source=./validation-helper.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/validation-helper.sh"

    wait_for_rr "${namespace}" 120
    poll_pipeline "${namespace}" "${timeout}" "${approve_mode}"
}

# Register the spoke as a remote target cluster with ArgoCD running on the
# hub, so a hub-side Application can sync resources onto the spoke (the
# GitOps-hub topology: git repo + ArgoCD live where the remediation
# workflow's credentials live, target workload lives on the spoke where the
# rest of fleet's monitoring stack already is -- see kubernaut#2326 for the
# WorkflowExecution.Spec.ClusterID decoupling this mirrors on the Kubernaut
# side).
#
# Bootstraps a cluster-admin ServiceAccount + token on the spoke for ArgoCD
# to authenticate as (demo-grade broad RBAC; a real deployment would scope
# this down), then writes the corresponding cluster registration Secret into
# the hub's ArgoCD namespace.
#
# A real fleet spoke's kubeconfig server is already routable from hub pods
# (that's the whole premise of two real clusters on a shared network). Local
# Kind dev runs both clusters as sibling containers on one Docker/Podman
# network instead, where the kubeconfig's server is a host-mapped loopback
# port that means nothing from inside a hub pod's network namespace -- this
# substitutes the spoke control-plane container's real Docker/Podman network
# IP in that case, verified reachable from a hub pod (`kubectl run ... curl
# https://<spoke-ip>:6443`) before wiring it into ArgoCD.
#
# Args: $1 = registered cluster label ArgoCD will show it as (default:
#       "spoke"), $2 = ArgoCD namespace on the hub (default: "argocd"),
#       $3 = spoke Kind cluster name, only needed for the loopback-
#       substitution case above (container name is "<name>-control-plane");
#       default: the spoke kubeconfig's current-context name with a
#       leading "kind-" stripped, kind's own naming convention.
#
# Prints the resolved server URL to stdout (for patching an Application's
# destination.server); all progress logging goes to stderr.
fleet_register_argocd_spoke_cluster() {
    _fleet_require_mode "fleet_register_argocd_spoke_cluster" || return 1
    local cluster_label="${1:-spoke}"
    local argocd_ns="${2:-argocd}"
    local kind_cluster_name="${3:-}"
    if [ -z "$kind_cluster_name" ]; then
        kind_cluster_name=$(kubectl --kubeconfig="${SPOKE_KUBECONFIG}" config view --minify -o jsonpath='{.current-context}' | sed 's/^kind-//')
    fi

    echo "==> [fleet] Bootstrapping ArgoCD manager ServiceAccount on spoke..." >&2
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" create serviceaccount argocd-manager -n kube-system \
        --dry-run=client -o yaml | kubectl --kubeconfig="${SPOKE_KUBECONFIG}" apply -f - >/dev/null
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" create clusterrolebinding argocd-manager \
        --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-manager \
        --dry-run=client -o yaml | kubectl --kubeconfig="${SPOKE_KUBECONFIG}" apply -f - >/dev/null
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF
    sleep 2
    local token
    token=$(kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get secret argocd-manager-token -n kube-system \
        -o jsonpath='{.data.token}' | base64 -d)
    if [ -z "$token" ]; then
        echo "ERROR: fleet_register_argocd_spoke_cluster: failed to mint a token for argocd-manager on the spoke." >&2
        return 1
    fi

    local server
    server=$(kubectl --kubeconfig="${SPOKE_KUBECONFIG}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
    if [[ "$server" =~ ^https://(127\.0\.0\.1|localhost) ]]; then
        local container="${kind_cluster_name}-control-plane"
        local ip
        ip=$(docker inspect "${container}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
        if [ -z "$ip" ]; then
            echo "ERROR: fleet_register_argocd_spoke_cluster: spoke kubeconfig server is loopback (${server}) and could not resolve '${container}' container IP for local Kind substitution." >&2
            return 1
        fi
        server="https://${ip}:6443"
        echo "  [fleet] Spoke kubeconfig server is loopback; substituting local Kind sibling-container address ${server}" >&2
    fi

    echo "==> [fleet] Registering spoke cluster '${cluster_label}' (${server}) with ArgoCD on hub..." >&2
    kubectl --kubeconfig="${HUB_KUBECONFIG}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${cluster_label}-cluster
  namespace: ${argocd_ns}
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${cluster_label}
  server: ${server}
  config: |
    {
      "bearerToken": "${token}",
      "tlsClientConfig": {
        "insecure": true
      }
    }
EOF
    echo "$server"
}

# One-call bootstrap for scenario run.sh scripts: ensures kube-state-metrics
# exists on the spoke and applies the scenario's operator monitoring
# resources (ServiceMonitor/PodMonitor/Probe/PrometheusRule) natively via
# fleet_deploy_monitoring. The operator reconciles CRD changes on its own --
# no config surgery, no restarts. No-op in single-cluster mode.
#
# Assumes the spoke's Prometheus accepts scenario monitoring CRDs
# (Prometheus/fleet-spoke selects all namespaces) and stamps
# cluster=remote-cluster via externalLabels.
#
# Args: $1 = manifest dir (e.g. the fleet_get_manifest_dir selection)
fleet_bootstrap_monitoring() {
    if ! is_fleet_mode; then
        return 0
    fi
    local manifest_dir="${1:?usage: fleet_bootstrap_monitoring <manifest-dir>}"
    fleet_ensure_kube_state_metrics
    fleet_deploy_monitoring "$manifest_dir"
}
