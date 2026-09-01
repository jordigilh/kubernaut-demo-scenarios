#!/usr/bin/env bash
# Fleet-mode helpers for demo scenario run.sh scripts.
# Source this from run.sh:
#   source "$(dirname "$0")/../../scripts/fleet-helper.sh"
#
# Fleet mode: hub cluster runs the Kubernaut control plane (catalog CRs,
# APIFrontend, Console, etc.); a separate spoke cluster runs the demo
# workload and is investigated/remediated remotely via the fleet MCP
# gateway. The spoke's Prometheus is a raw (hand-rolled, no
# prometheus-operator) instance, so scenario PrometheusRule CRDs cannot be
# applied there directly -- there is no monitoring.coreos.com CRD to accept
# them. These helpers bridge that gap: they translate a scenario's
# manifests/prometheus-rule.yaml into the raw rule_files format the spoke's
# Prometheus actually consumes, and ensure kube-state-metrics exists (the
# spoke only scrapes kubelet-cadvisor by default, so any rule keying off
# kube_state_metrics_* / kube_pod_* series would otherwise never fire).
#
# Fleet mode is opt-in and detected via two env vars; every function below
# is a no-op (or must not be called) when they are unset, so single-cluster
# scenarios are unaffected.
#
#   HUB_KUBECONFIG    kubeconfig for the cluster running the Kubernaut
#                      control plane
#   SPOKE_KUBECONFIG   kubeconfig for the cluster running the demo workload

is_fleet_mode() {
    [ -n "${HUB_KUBECONFIG:-}" ] && [ -n "${SPOKE_KUBECONFIG:-}" ]
}

_fleet_require_mode() {
    if ! is_fleet_mode; then
        echo "ERROR: $1 requires HUB_KUBECONFIG and SPOKE_KUBECONFIG to be set." >&2
        return 1
    fi
}

FLEET_MONITORING_NS="${FLEET_MONITORING_NS:-monitoring}"

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
# PodMonitor documents in the manifest dir -- the spoke has no
# prometheus-operator CRDs to accept them (use fleet_load_prometheus_rule +
# fleet_ensure_scrape_job/fleet_ensure_pod_scrape_job for the raw-Prometheus
# equivalents instead).
#
# Args: $1 = manifest dir (e.g. scenarios/crashloop/manifests)
fleet_deploy_workload() {
    _fleet_require_mode "fleet_deploy_workload" || return 1
    local manifest_dir="${1:?usage: fleet_deploy_workload <manifest-dir>}"

    echo "==> [fleet] Deploying workload manifests to spoke (skipping PrometheusRule/ServiceMonitor/Probe/PodMonitor -- no operator on spoke)..."
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir}"' RETURN

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
        if grep -qE 'kind: (PrometheusRule|ServiceMonitor|Probe|PodMonitor)' "$doc"; then
            skipped=$((skipped + 1))
            continue
        fi
        kubectl --kubeconfig="${SPOKE_KUBECONFIG}" apply -f "$doc" 2>&1 | sed 's/^/    /'
        applied=$((applied + 1))
    done
    echo "  Applied ${applied} document(s) to spoke, skipped ${skipped} (operator-only kinds)."
}

# Ensure kube-state-metrics is deployed on the spoke's monitoring namespace.
# Idempotent: no-op if the Deployment already exists.
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

# Translate a scenario's manifests/prometheus-rule.yaml (a PrometheusRule CRD)
# into the spoke's raw Prometheus rule_files format and load it, adding a
# kube-state-metrics scrape job to prometheus-config if not already present.
# Idempotent: compares content hashes and skips the rollout when nothing
# changed (the Deployment patch that mounts the rules volume only runs once).
#
# Args: $1 = path to the scenario's manifests/prometheus-rule.yaml
fleet_load_prometheus_rule() {
    _fleet_require_mode "fleet_load_prometheus_rule" || return 1
    local rule_file="${1:?usage: fleet_load_prometheus_rule <prometheus-rule.yaml>}"

    if [ ! -f "$rule_file" ]; then
        echo "  [fleet] No PrometheusRule at ${rule_file}, skipping rule load."
        return 0
    fi

    local rule_name rules_yaml
    # Every scenario's PrometheusRule is conventionally named "demo-app-alerts"
    # (disambiguated by CRD namespace, like the OCP overlays' -monitoring/
    # -analytics/etc. suffixes do). The spoke's raw rule_files ConfigMap has
    # no such per-namespace isolation, so key by namespace+name to avoid one
    # scenario's rule silently overwriting another's ConfigMap entry.
    rule_name=$(python3 -c "
import yaml, sys
doc = yaml.safe_load(open(sys.argv[1]))
print(f\"{doc['metadata']['namespace']}-{doc['metadata']['name']}\")
" "$rule_file")
    rules_yaml=$(python3 -c "
import yaml, sys
doc = yaml.safe_load(open(sys.argv[1]))
print(yaml.dump({'groups': doc['spec']['groups']}, default_flow_style=False))
" "$rule_file")

    local desired_hash current_hash
    desired_hash=$(printf '%s' "$rules_yaml" | shasum -a 256 | cut -d' ' -f1)
    current_hash=$(kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get configmap prometheus-rules \
        -n "${FLEET_MONITORING_NS}" -o jsonpath="{.data.${rule_name}\.yml}" 2>/dev/null \
        | shasum -a 256 | cut -d' ' -f1 || true)

    if [ "$desired_hash" = "$current_hash" ]; then
        echo "  [fleet] Prometheus rule '${rule_name}' already loaded on spoke."
    else
        echo "==> [fleet] Loading Prometheus rule '${rule_name}' onto spoke (raw rule_files, no operator)..."
        # Merge into the existing ConfigMap's data rather than replacing it --
        # kubectl apply's 3-way merge (vs. last-applied-configuration) would
        # otherwise treat every *other* scenario's key as removed, since a
        # bare `create --from-literal | apply` only ever declares one key.
        kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get configmap prometheus-rules \
            -n "${FLEET_MONITORING_NS}" -o json 2>/dev/null \
            | python3 -c "
import sys, json
try:
    cm = json.load(sys.stdin)
except json.JSONDecodeError:
    cm = {}
if not cm:
    cm = {'apiVersion': 'v1', 'kind': 'ConfigMap',
          'metadata': {'name': 'prometheus-rules', 'namespace': '${FLEET_MONITORING_NS}'}}
cm.setdefault('data', {})['${rule_name}.yml'] = sys.argv[1]
json.dump(cm, sys.stdout)
" "$rules_yaml" | kubectl --kubeconfig="${SPOKE_KUBECONFIG}" apply -f - 2>&1 | sed 's/^/    /'
        # Prometheus only globs /etc/prometheus/rules/*.yml at startup/reload,
        # not continuously -- a new or changed rule file needs a restart to
        # be picked up, same as the prometheus-config edits below.
        _FLEET_PROM_CONFIG_CHANGED=1
    fi

    # Ensure the Deployment mounts the rules ConfigMap (one-time; idempotent
    # via a JSON-pointer existence check rather than a second apply, since
    # strategic-merge would otherwise duplicate the volume/mount on rerun).
    if ! kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get deployment prometheus -n "${FLEET_MONITORING_NS}" \
        -o jsonpath='{.spec.template.spec.volumes[?(@.name=="rules")]}' 2>/dev/null | grep -q rules; then
        echo "  [fleet] Mounting rules ConfigMap onto spoke Prometheus..."
        kubectl --kubeconfig="${SPOKE_KUBECONFIG}" patch deployment prometheus -n "${FLEET_MONITORING_NS}" --type=json -p='[
          {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"rules","configMap":{"name":"prometheus-rules"}}},
          {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"rules","mountPath":"/etc/prometheus/rules"}}
        ]' 2>&1 | sed 's/^/    /'
    fi

    _fleet_ensure_prometheus_config_has "rule_files" "- /etc/prometheus/rules/*.yml"
    _fleet_ensure_prometheus_config_has "kube-state-metrics scrape job" \
        "- job_name: 'kube-state-metrics'
  scrape_interval: 15s
  static_configs:
  - targets: ['kube-state-metrics.${FLEET_MONITORING_NS}.svc.cluster.local:8080']"
}

# Ensure a fragment of raw Prometheus YAML config is present in the spoke's
# prometheus-config ConfigMap, appending it (and rolling out Prometheus) only
# if missing. Uses substring matching, not YAML merge -- the spoke's
# prometheus.yml is small and hand-maintained (test/infrastructure/fleet_e2e.go
# generates it), so a full parse/merge would be more fragile than this for the
# handful of fragments scenarios need to add.
_fleet_ensure_prometheus_config_has() {
    local description="$1" fragment="$2"
    local current
    current=$(kubectl --kubeconfig="${SPOKE_KUBECONFIG}" get configmap prometheus-config \
        -n "${FLEET_MONITORING_NS}" -o jsonpath='{.data.prometheus\.yml}' 2>/dev/null || true)

    if echo "$current" | grep -qF -- "$(echo "$fragment" | head -1)"; then
        return 0
    fi

    echo "  [fleet] Adding ${description} to spoke prometheus-config..."
    local updated
    if [ "$description" = "rule_files" ]; then
        updated="global:
$(echo "$current" | sed -n '/^global:/,/^[a-z]/p' | sed '1d;$d')
rule_files:
${fragment}
$(echo "$current" | sed -n '/^scrape_configs:/,$p')"
    else
        updated=$(python3 -c "
import sys
current = sys.argv[1]
fragment = sys.argv[2]
lines = current.split(chr(10))
out = []
i = 0
while i < len(lines):
    out.append(lines[i])
    if lines[i].startswith('scrape_configs:'):
        # insert after the whole scrape_configs block, i.e. before 'alerting:'
        pass
    i += 1
text = chr(10).join(out)
marker = chr(10) + 'alerting:'
if marker in text:
    text = text.replace(marker, chr(10) + fragment + marker, 1)
else:
    text = text + chr(10) + fragment + chr(10)
print(text)
" "$current" "$fragment")
    fi

    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" create configmap prometheus-config \
        -n "${FLEET_MONITORING_NS}" --from-literal="prometheus.yml=${updated}" \
        --dry-run=client -o yaml | kubectl --kubeconfig="${SPOKE_KUBECONFIG}" apply -f - 2>&1 | sed 's/^/    /'

    _FLEET_PROM_CONFIG_CHANGED=1
}

# Ensure an additional static-target scrape job exists on the spoke's raw
# Prometheus, for scenarios whose alert depends on a metrics endpoint other
# than kube-state-metrics/kubelet-cadvisor -- e.g. cert-manager, etcd, or a
# scenario's own exporter Service. Verified live (kubernaut-demo-scenarios
# spike, 2026-09-01): cert-manager's own metrics Service
# (cert-manager.cert-manager.svc.cluster.local:9402) is a stable in-cluster
# target, scraped the exact same way kube-state-metrics already is below --
# no operator/ServiceMonitor required on the spoke. Not every custom metric
# fits this shape (Istio's per-pod sidecar metrics and blackbox_exporter's
# Probe-style /probe?target=... scraping need a different scrape_configs
# shape entirely), but it covers any scenario whose custom metric comes from
# a single well-known Service:port. No-op if a job with this name already
# exists (matched by job_name, so keep job_name unique per scenario). Call
# fleet_reload_spoke_prometheus afterward to pick up the change.
#
# Args: $1 = job_name, $2 = target (host:port), $3 = optional extra
#       scrape_configs YAML lines (e.g. metrics_path/params), indented to
#       match the job's top level. $4 = optional static labels to attach
#       directly to this target (e.g. when the exporter itself has no
#       concept of a k8s namespace, unlike cert-manager's own metrics --
#       postgres_exporter's pg_stat_activity_count is one such case),
#       indented to match under the static_configs target item.
fleet_ensure_scrape_job() {
    _fleet_require_mode "fleet_ensure_scrape_job" || return 1
    local job_name="${1:?usage: fleet_ensure_scrape_job <job_name> <target> [extra_yaml] [target_labels_yaml]}"
    local target="${2:?usage: fleet_ensure_scrape_job <job_name> <target> [extra_yaml] [target_labels_yaml]}"
    local extra="${3:-}"
    local target_labels="${4:-}"
    local fragment="- job_name: '${job_name}'
  scrape_interval: 15s"
    if [ -n "$extra" ]; then
        fragment="${fragment}
${extra}"
    fi
    fragment="${fragment}
  static_configs:
  - targets: ['${target}']"
    if [ -n "$target_labels" ]; then
        fragment="${fragment}
    labels:
${target_labels}"
    fi
    _fleet_ensure_prometheus_config_has "'${job_name}' scrape job" "$fragment"
}

# Ensure a scrape job against kubelet's main /metrics endpoint (not the
# /metrics/cadvisor sub-path the existing kubelet-cadvisor job uses)
# exists, for scenarios keying off metrics kubelet exposes itself rather
# than via cAdvisor -- e.g. kubelet_volume_stats_* (PVC capacity/usage),
# which cAdvisor doesn't report. Same kubernetes_sd_configs shape as
# kubelet-cadvisor (role: node, scrape the node's kubelet port directly),
# just a different path and metric_relabel_configs keep filter, so this
# doesn't fit fleet_ensure_scrape_job's single-static-target shape.
#
# Args: $1 = job_name (must be unique), $2 = regex of metric names to keep
#       (passed through metric_relabel_configs, e.g.
#       'kubelet_volume_stats_(used_bytes|capacity_bytes)').
fleet_ensure_kubelet_metrics_job() {
    _fleet_require_mode "fleet_ensure_kubelet_metrics_job" || return 1
    local job_name="${1:?usage: fleet_ensure_kubelet_metrics_job <job_name> <keep_regex>}"
    local keep_regex="${2:?usage: fleet_ensure_kubelet_metrics_job <job_name> <keep_regex>}"
    local fragment="- job_name: '${job_name}'
  scrape_interval: 15s
  kubernetes_sd_configs:
  - role: node
  scheme: https
  tls_config:
    insecure_skip_verify: true
  bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
  relabel_configs:
  - source_labels: [__meta_kubernetes_node_address_InternalIP]
    target_label: __address__
    replacement: \${1}:10250
  metric_relabel_configs:
  - source_labels: [__name__]
    regex: '${keep_regex}'
    action: keep"
    _fleet_ensure_prometheus_config_has "'${job_name}' scrape job" "$fragment"
}

# Ensure a per-pod scrape job (kubernetes_sd_configs role: pod, scoped to one
# namespace) exists, for sidecar/per-pod metrics with no single stable
# Service endpoint to hit statically -- e.g. istio-proxy's Envoy stats port,
# which exists once per meshed pod, not behind one shared Service. Unlike
# fleet_ensure_scrape_job (one static target) or fleet_ensure_kubelet_metrics_job
# (role: node), this discovers pods dynamically so it keeps working as pods
# are added/removed/rescheduled -- the same thing a PodMonitor would do via
# prometheus-operator, reproduced by hand for the spoke's raw Prometheus.
#
# Args: $1 = job_name, $2 = namespace to discover pods in, $3 = metrics_path,
#       $4 = full relabel_configs block (verbatim, caller's responsibility --
#       typically a container-name/port-name "keep" filter first, since
#       role: pod emits one target per exposed container port, then a
#       namespace/pod label rewrite from __meta_kubernetes_namespace/
#       __meta_kubernetes_pod_name -- prometheus-operator's PodMonitor
#       controller adds this namespace relabeling automatically; there's no
#       operator here to do it for us).
fleet_ensure_pod_scrape_job() {
    _fleet_require_mode "fleet_ensure_pod_scrape_job" || return 1
    local job_name="${1:?usage: fleet_ensure_pod_scrape_job <job_name> <namespace> <metrics_path> <relabel_configs_yaml>}"
    local target_ns="${2:?usage: fleet_ensure_pod_scrape_job <job_name> <namespace> <metrics_path> <relabel_configs_yaml>}"
    local metrics_path="${3:?usage: fleet_ensure_pod_scrape_job <job_name> <namespace> <metrics_path> <relabel_configs_yaml>}"
    local relabel="${4:?usage: fleet_ensure_pod_scrape_job <job_name> <namespace> <metrics_path> <relabel_configs_yaml>}"
    local fragment="- job_name: '${job_name}'
  scrape_interval: 15s
  metrics_path: ${metrics_path}
  kubernetes_sd_configs:
  - role: pod
    namespaces:
      names: ['${target_ns}']
  relabel_configs:
${relabel}"
    _fleet_ensure_prometheus_config_has "'${job_name}' pod-scrape job" "$fragment"
}

# Roll out the spoke Prometheus if fleet_load_prometheus_rule changed its
# config or mounted a new volume. Call once after all fleet_load_prometheus_rule
# calls for a scenario, not per-call, to avoid redundant restarts.
fleet_reload_spoke_prometheus() {
    _fleet_require_mode "fleet_reload_spoke_prometheus" || return 1
    if [ "${_FLEET_PROM_CONFIG_CHANGED:-0}" != "1" ]; then
        return 0
    fi
    echo "==> [fleet] Rolling out spoke Prometheus to pick up config changes..."
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" rollout restart deployment/prometheus -n "${FLEET_MONITORING_NS}"
    kubectl --kubeconfig="${SPOKE_KUBECONFIG}" rollout status deployment/prometheus \
        -n "${FLEET_MONITORING_NS}" --timeout=90s | sed 's/^/    /'
    _FLEET_PROM_CONFIG_CHANGED=0
}

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
    # Optional disambiguator for multi-spoke demos: every spoke's Prometheus
    # stamps its alerts with global.external_labels.cluster (see
    # prometheus-config on the spoke), which Alertmanager preserves on the
    # hub. Pass this (or set SPOKE_CLUSTER_LABEL) to confirm the alert from
    # one specific spoke when several spokes run the same scenario/
    # namespace concurrently. Left unset (the default), matches any
    # cluster -- today's single-spoke behavior.
    local cluster="${4:-${SPOKE_CLUSTER_LABEL:-}}"

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

# One-call bootstrap for scenario run.sh scripts: deploys kube-state-metrics
# and loads the scenario's PrometheusRule onto the spoke, then rolls out
# Prometheus if anything changed. No-op in single-cluster mode.
#
# Args: $1 = path to the scenario's manifests/prometheus-rule.yaml
fleet_bootstrap_monitoring() {
    if ! is_fleet_mode; then
        return 0
    fi
    local rule_file="${1:?usage: fleet_bootstrap_monitoring <prometheus-rule.yaml>}"
    fleet_ensure_kube_state_metrics
    fleet_load_prometheus_rule "$rule_file"
    fleet_reload_spoke_prometheus
}
