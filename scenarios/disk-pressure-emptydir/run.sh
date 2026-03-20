#!/usr/bin/env bash
# DiskPressure emptyDir Migration Demo -- Automated Runner (Proactive)
# Scenario #324: PostgreSQL on emptyDir fills disk -> PredictedDiskPressure (proactive) ->
# SP normalizes to DiskPressure -> LLM detects antipattern -> RAR ->
# Ansible backs up DB (live pg_dump), commits PVC migration to Git ->
# ArgoCD syncs -> restore -> EA verifies
#
# Flagship enterprise demo: proactive signal (BR-SP-106) + LLM + RAR + Ansible/AAP + GitOps + audit trail
#
# Prerequisites:
#   - Kind cluster with custom kubelet eviction threshold OR OCP with kcli worker
#   - AWX deployed (run: bash scripts/awx-helper.sh)
#   - Gitea + ArgoCD deployed
#   - Prometheus with kube-state-metrics
#
# Usage:
#   ./scenarios/disk-pressure-emptydir/run.sh
#   ./scenarios/disk-pressure-emptydir/run.sh setup
#   ./scenarios/disk-pressure-emptydir/run.sh inject
#   ./scenarios/disk-pressure-emptydir/run.sh all
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-diskpressure"
GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="kubernaut"
GITEA_ADMIN_PASS="kubernaut123"
REPO_NAME="demo-diskpressure-repo"

APPROVE_MODE="--auto-approve"
SKIP_VALIDATE=""
SUBCOMMAND="all"
for _arg in "$@"; do
    case "$_arg" in
        --auto-approve)  APPROVE_MODE="--auto-approve" ;;
        --interactive)   APPROVE_MODE="--interactive" ;;
        --no-validate)   SKIP_VALIDATE=true ;;
        setup|inject|all) SUBCOMMAND="$_arg" ;;
    esac
done

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
require_demo_ready
# shellcheck source=../../scripts/monitoring-helper.sh
source "${SCRIPT_DIR}/../../scripts/monitoring-helper.sh"
require_infra awx
require_infra gitea
require_infra argocd

# shellcheck source=../../scripts/gitops-helper.sh
source "${SCRIPT_DIR}/../../scripts/gitops-helper.sh"

# Verify webhook CA bundle is correctly patched on all Validating/Mutating
# webhook configurations owned by Kubernaut. After an interrupted helm install
# the CA bundle may be empty, causing all CR validation to fail with TLS errors.
# See: kubernaut-demo-scenarios#3 sub-issue 3.1
_verify_webhook_ca_bundle() {
    local ca_data
    ca_data=$(kubectl get configmap authwebhook-ca -n "${PLATFORM_NS}" \
      -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
    if [ -z "$ca_data" ]; then
        echo "  WARNING: authwebhook-ca ConfigMap not found or empty; skipping CA bundle check."
        return 0
    fi

    local ca_b64
    ca_b64=$(printf '%s' "$ca_data" | base64 | tr -d '\n')

    for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
        local configs
        configs=$(kubectl get "$kind" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i authwebhook || true)
        for cfg in $configs; do
            local count
            count=$(kubectl get "$kind" "$cfg" -o json 2>/dev/null | \
              python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('webhooks',[])))" 2>/dev/null || echo "0")
            for idx in $(seq 0 $((count - 1))); do
                local existing
                existing=$(kubectl get "$kind" "$cfg" -o jsonpath="{.webhooks[${idx}].clientConfig.caBundle}" 2>/dev/null || true)
                if [ -z "$existing" ]; then
                    echo "  Patching empty caBundle on ${kind}/${cfg} webhook[${idx}]..."
                    kubectl patch "$kind" "$cfg" --type='json' \
                      -p "[{\"op\":\"replace\",\"path\":\"/webhooks/${idx}/clientConfig/caBundle\",\"value\":\"${ca_b64}\"}]" 2>/dev/null || true
                fi
            done
        done
    done
    echo "  Webhook CA bundles verified."
}

# On OCP, ensure the Alertmanager ServiceAccount can POST signals to the Gateway.
# The chart creates the ClusterRole but not the OCP-specific ClusterRoleBinding.
# See: kubernaut-demo-scenarios#3 sub-issue 3.2
_ensure_alertmanager_rbac() {
    if [ "$PLATFORM" != "ocp" ]; then
        return 0
    fi
    if kubectl get clusterrolebinding alertmanager-ocp-gateway-signal-source &>/dev/null; then
        echo "  Alertmanager ClusterRoleBinding already exists."
        return 0
    fi
    if ! kubectl get clusterrole gateway-signal-source &>/dev/null; then
        echo "  WARNING: gateway-signal-source ClusterRole not found; chart may not be installed yet."
        return 0
    fi
    kubectl create clusterrolebinding alertmanager-ocp-gateway-signal-source \
      --clusterrole=gateway-signal-source \
      --serviceaccount=openshift-monitoring:alertmanager-main \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "  Created Alertmanager -> Gateway RBAC binding (OCP)."
}

# Create gitea-repo-creds secret for workflow dependency validation.
# See: kubernaut-demo-scenarios#3 sub-issue 3.5
_ensure_gitea_repo_creds() {
    local ns="kubernaut-workflows"
    if ! kubectl get namespace "$ns" &>/dev/null; then
        echo "  WARNING: ${ns} namespace does not exist yet; skipping gitea-repo-creds."
        return 0
    fi
    kubectl create secret generic gitea-repo-creds \
      -n "$ns" \
      --from-literal=username="${GITEA_ADMIN_USER}" \
      --from-literal=password="${GITEA_ADMIN_PASS}" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "  gitea-repo-creds secret ensured in ${ns}."
}

# Warn (non-fatal) if required secrets are missing before setup proceeds.
# See: kubernaut-demo-scenarios#3 sub-issue 3.7
_check_prerequisites() {
    local missing=false
    if ! kubectl get secret llm-credentials -n "${PLATFORM_NS}" &>/dev/null; then
        echo "  WARNING: llm-credentials secret not found in ${PLATFORM_NS}."
        echo "    Create it before running the scenario:"
        echo "      kubectl create secret generic llm-credentials -n ${PLATFORM_NS} \\"
        echo "        --from-literal=OPENAI_API_KEY=sk-..."
        missing=true
    fi
    if ! kubectl get secret slack-webhook -n "${PLATFORM_NS}" &>/dev/null; then
        echo "  NOTE: slack-webhook secret not found in ${PLATFORM_NS} (notifications will use console only)."
    fi
    if [ "$missing" = true ]; then
        echo ""
        echo "  Setup will continue, but the pipeline may fail without LLM credentials."
        echo ""
    fi
}

run_setup() {
echo "============================================="
echo " DiskPressure emptyDir Migration Demo (#324)"
echo " emptyDir growth -> PredictedDiskPressure"
echo " (proactive, BR-SP-106) -> Ansible/AWX"
echo " -> GitOps PVC migration -> DB restore"
echo ""
echo " Rate auto-tuned to node filesystem capacity"
echo "============================================="
echo ""

echo "==> Checking prerequisites..."
_check_prerequisites

# Step 0: Ensure a worker node has the scenario label and taint.
# On Kind, kind-config-diskpressure.yaml bakes the label at cluster creation.
# On OCP, we pick the first schedulable worker and label it.
_ensure_scenario_node() {
    if kubectl get nodes -l scenario=disk-pressure -o name 2>/dev/null | grep -q .; then
        echo "  Node with scenario=disk-pressure already exists."
        return 0
    fi
    local target
    target=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$target" ]; then
        echo "  WARNING: no schedulable worker node found; pods may stay Pending."
        return 0
    fi
    echo "  Labeling and tainting node ${target} for disk-pressure scenario..."
    kubectl label node "$target" scenario=disk-pressure --overwrite
    kubectl taint node "$target" scenario=disk-pressure:NoSchedule --overwrite 2>/dev/null || true
}
echo "==> Step 0: Ensuring a worker node is labeled for this scenario..."
_ensure_scenario_node

_patch_prometheusrule_for_ocp() {
    if [ "${PLATFORM:-kind}" != "ocp" ]; then
        return 0
    fi
    local target_node
    target_node=$(kubectl get nodes -l scenario=disk-pressure \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$target_node" ]; then
        echo "  WARNING: no scenario node found, skipping PromQL patch."
        return 0
    fi
    echo "  Patching PrometheusRule PromQL for OCP (mountpoint=/var, node=${target_node})..."
    kubectl get prometheusrule demo-diskpressure-rules -n "${NAMESPACE}" -o json | \
      jq --arg node "$target_node" \
        '.spec.groups[0].rules[0].expr = "predict_linear(node_filesystem_avail_bytes{mountpoint=\"/var\", instance=~\"" + $node + ".*\"}[3m], 1200) < 0"' | \
      kubectl apply -f -
}

# Step 1: Push deployment YAML to Gitea repo
echo "==> Step 1: Pushing deployment manifests to Gitea..."
WORK_DIR=$(mktemp -d)
gitea_connect

curl -sk -X POST "${GITEA_API_URL}/api/v1/user/repos" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${REPO_NAME}\", \"auto_init\": true}" -o /dev/null 2>/dev/null || true

cd "${WORK_DIR}"
git clone "${GITEA_GIT_BASE}/${REPO_NAME}.git" repo 2>/dev/null
cd repo
git config user.email "kubernaut@kubernaut.ai"
git config user.name "Kubernaut Setup"

mkdir -p disk-pressure-emptydir

# Platform-specific PostgreSQL settings
if [ "$PLATFORM" = "ocp" ]; then
    PG_IMAGE="registry.redhat.io/rhel9/postgresql-16"
    PG_ENV_USER="POSTGRESQL_USER"
    PG_ENV_DB="POSTGRESQL_DATABASE"
    PG_ENV_PASS="POSTGRESQL_PASSWORD"
    PG_DATA_MOUNT="/var/lib/pgsql/data"
    PG_DATA_VALUE="/var/lib/pgsql/data/userdata"
else
    PG_IMAGE="postgres:16-alpine"
    PG_ENV_USER="POSTGRES_USER"
    PG_ENV_DB="POSTGRES_DB"
    PG_ENV_PASS="POSTGRES_PASSWORD"
    PG_DATA_MOUNT="/var/lib/postgresql/data"
    PG_DATA_VALUE="/var/lib/postgresql/data/pgdata"
fi

cat > disk-pressure-emptydir/deployment.yaml <<MANIFEST
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-emptydir
  namespace: demo-diskpressure
  labels:
    app: postgres-emptydir
    kubernaut.ai/managed: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres-emptydir
  template:
    metadata:
      labels:
        app: postgres-emptydir
    spec:
      nodeSelector:
        scenario: disk-pressure
      tolerations:
      - key: scenario
        value: disk-pressure
        effect: NoSchedule
      containers:
      - name: postgres
        image: ${PG_IMAGE}
        ports:
        - containerPort: 5432
        env:
        - name: ${PG_ENV_USER}
          value: "postgres"
        - name: ${PG_ENV_DB}
          value: "postgres"
        - name: ${PG_ENV_PASS}
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: password
        - name: PGDATA
          value: "${PG_DATA_VALUE}"
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        volumeMounts:
        - name: data
          mountPath: ${PG_DATA_MOUNT}
        - name: init-sql
          mountPath: /docker-entrypoint-initdb.d
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "postgres"]
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: data
        emptyDir: {}
      - name: init-sql
        configMap:
          name: postgres-init-sql
MANIFEST

cat > disk-pressure-emptydir/secret.yaml <<'MANIFEST'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: demo-diskpressure
type: Opaque
stringData:
  password: "kubernaut-demo-pass"
MANIFEST

cat > disk-pressure-emptydir/service.yaml <<'MANIFEST'
apiVersion: v1
kind: Service
metadata:
  name: postgres-emptydir
  namespace: demo-diskpressure
spec:
  selector:
    app: postgres-emptydir
  ports:
  - port: 5432
    targetPort: 5432
MANIFEST

cat > disk-pressure-emptydir/configmap.yaml <<'MANIFEST'
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init-sql
  namespace: demo-diskpressure
data:
  init.sql: |
    CREATE TABLE IF NOT EXISTS events (
        id         SERIAL PRIMARY KEY,
        timestamp  TIMESTAMPTZ NOT NULL DEFAULT now(),
        source     TEXT NOT NULL DEFAULT 'sensor',
        payload    TEXT NOT NULL
    );
    CREATE OR REPLACE PROCEDURE simulate_data_growth(
        batch_size  INT DEFAULT 500,
        num_iters   INT DEFAULT 200,
        sleep_ms    INT DEFAULT 100
    )
    LANGUAGE plpgsql AS $$
    DECLARE
        i INT;
    BEGIN
        FOR i IN 1..num_iters LOOP
            INSERT INTO events (source, payload)
            SELECT
                'sensor-' || (random()*100)::int,
                repeat(md5(random()::text), 32)
            FROM generate_series(1, batch_size);
            COMMIT;
            PERFORM pg_sleep(sleep_ms / 1000.0);
        END LOOP;
    END;
    $$;
MANIFEST

cat > disk-pressure-emptydir/noise-deployments.yaml <<'MANIFEST'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-cache
  namespace: demo-diskpressure
  labels:
    app: nginx-cache
    role: noise
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-cache
  template:
    metadata:
      labels:
        app: nginx-cache
        role: noise
    spec:
      nodeSelector:
        scenario: disk-pressure
      tolerations:
      - key: scenario
        value: disk-pressure
        effect: NoSchedule
      initContainers:
      - name: cache-warmup
        image: busybox:1.36
        command:
        - /bin/sh
        - -c
        - |
          echo "Warming up nginx cache (~200MB)..."
          for i in $(seq 1 200); do
            dd if=/dev/urandom bs=1M count=1 of=/tmp/nginx-cache/cached-page-${i}.dat 2>/dev/null
            sleep 1
          done
          echo "Cache warm-up complete."
        volumeMounts:
        - name: cache
          mountPath: /tmp/nginx-cache
      containers:
      - name: nginx
        image: nginxinc/nginx-unprivileged:1.27-alpine
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        volumeMounts:
        - name: cache
          mountPath: /tmp/nginx-cache
      volumes:
      - name: cache
        emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-collector
  namespace: demo-diskpressure
  labels:
    app: log-collector
    role: noise
spec:
  replicas: 1
  selector:
    matchLabels:
      app: log-collector
  template:
    metadata:
      labels:
        app: log-collector
        role: noise
    spec:
      nodeSelector:
        scenario: disk-pressure
      tolerations:
      - key: scenario
        value: disk-pressure
        effect: NoSchedule
      containers:
      - name: logger
        image: busybox:1.36
        command:
        - /bin/sh
        - -c
        - |
          i=0
          while true; do
            dd if=/dev/urandom bs=256K count=1 of=/var/log/app/logfile-${i}.log 2>/dev/null
            i=$((i + 1))
            sleep 5
          done
        resources:
          requests:
            memory: "32Mi"
            cpu: "25m"
          limits:
            memory: "64Mi"
            cpu: "50m"
        volumeMounts:
        - name: logs
          mountPath: /var/log/app
      volumes:
      - name: logs
        emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-scratch
  namespace: demo-diskpressure
  labels:
    app: redis-scratch
    role: noise
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-scratch
  template:
    metadata:
      labels:
        app: redis-scratch
        role: noise
    spec:
      nodeSelector:
        scenario: disk-pressure
      tolerations:
      - key: scenario
        value: disk-pressure
        effect: NoSchedule
      containers:
      - name: redis
        image: redis:7-alpine
        args: ["--appendonly", "yes", "--dir", "/data"]
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        volumeMounts:
        - name: data
          mountPath: /data
      - name: session-loader
        image: busybox:1.36
        command:
        - /bin/sh
        - -c
        - |
          i=0
          while [ $i -lt 200 ]; do
            dd if=/dev/urandom bs=512K count=1 of=/data/aof-segment-${i}.dat 2>/dev/null
            i=$((i + 1))
            sleep 2
          done
          echo "Session data stable at ~100MB."
          while true; do sleep 3600; done
        resources:
          requests:
            memory: "16Mi"
            cpu: "10m"
          limits:
            memory: "32Mi"
            cpu: "50m"
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        emptyDir: {}
MANIFEST

cat > disk-pressure-emptydir/kustomization.yaml <<'MANIFEST'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - noise-deployments.yaml
  - secret.yaml
  - service.yaml
  - configmap.yaml
MANIFEST

git add .
if git diff --cached --quiet 2>/dev/null; then
    echo "  Gitea repo already has deployment manifests."
else
    git commit -m "feat: initial postgres-emptydir deployment (emptyDir volume)"
    git push origin main
    echo "  Deployment manifests pushed to Gitea."
fi

gitea_disconnect
cd /
rm -rf "${WORK_DIR}"

# Step 1b: Ensure gitea-repo-creds secret exists for workflow dependency validation
echo "==> Step 1b: Ensuring gitea-repo-creds secret..."
_ensure_gitea_repo_creds

# Step 2: Apply all manifests (namespace, Prometheus rule, ArgoCD Application)
echo "==> Step 2: Applying manifests (namespace, Prometheus rule, ArgoCD Application)..."

echo "  Verifying webhook CA bundles..."
_verify_webhook_ca_bundle

echo "  Ensuring Alertmanager RBAC..."
_ensure_alertmanager_rbac

MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"
_patch_prometheusrule_for_ocp

# Speed up ArgoCD polling for demo
ARGOCD_NS=$(get_argocd_namespace)
kubectl patch configmap argocd-cm -n "${ARGOCD_NS}" --type merge \
  -p '{"data":{"timeout.reconciliation":"60s"}}' 2>/dev/null || true

# Step 2b: Configure Gitea -> ArgoCD webhook for instant sync on push.
# The remediation playbook pushes a PVC migration commit; without this
# webhook ArgoCD would poll with up to 3 min delay.
echo "==> Step 2b: Ensuring Gitea webhook notifies ArgoCD on push..."
setup_gitea_argocd_webhook "${GITEA_ADMIN_USER}" "${REPO_NAME}"

# Step 3: Wait for ArgoCD sync and PostgreSQL readiness
echo "==> Step 3: Waiting for ArgoCD sync..."
for i in $(seq 1 60); do
    if kubectl get deployment postgres-emptydir -n "${NAMESPACE}" &>/dev/null; then
        echo "  ArgoCD synced deployment (attempt ${i})."
        break
    fi
    sleep 5
done

echo "==> Step 4: Waiting for PostgreSQL and noise pods readiness..."
echo "  (nginx-cache has a ~3 min init container for cache warm-up)"
kubectl wait --for=condition=Available deployment/postgres-emptydir \
  -n "${NAMESPACE}" --timeout=180s
echo "  PostgreSQL is running with emptyDir storage."
for noise_dep in log-collector redis-scratch; do
    kubectl wait --for=condition=Available "deployment/${noise_dep}" \
      -n "${NAMESPACE}" --timeout=120s 2>/dev/null && \
      echo "  ${noise_dep} is running." || \
      echo "  WARNING: ${noise_dep} not ready (non-fatal)."
done
kubectl wait --for=condition=Available deployment/nginx-cache \
  -n "${NAMESPACE}" --timeout=300s 2>/dev/null && \
  echo "  nginx-cache is running (cache warm-up complete)." || \
  echo "  WARNING: nginx-cache not ready (non-fatal)."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 5: Run init SQL explicitly.
# The standard Docker image auto-runs /docker-entrypoint-initdb.d/*.sql, but the
# Red Hat sclorg image does not. Run it via psql for both platforms.
echo "==> Step 5: Running init SQL..."
local init_pod
init_pod=$(kubectl get pods -n "${NAMESPACE}" -l app=postgres-emptydir \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "${NAMESPACE}" "${init_pod}" -- \
  psql -U postgres -d postgres -f /docker-entrypoint-initdb.d/init.sql 2>&1 | sed 's/^/    /'
echo "  simulate_data_growth() procedure is available."
echo ""
}

_label_target_node() {
    local pod node
    pod=$(kubectl get pods -n "${NAMESPACE}" -l app=postgres-emptydir \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    node=$(kubectl get pod "$pod" -n "${NAMESPACE}" \
      -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    if [ -z "$node" ]; then
        echo "WARNING: could not determine target node for PredictedDiskPressure signal"
        return 0
    fi
    echo "==> Labeling node ${node} for Kubernaut signal acceptance..."
    kubectl label node "$node" \
        kubernaut.ai/managed=true \
        kubernaut.ai/environment=production \
        kubernaut.ai/business-unit=infrastructure \
        kubernaut.ai/service-owner=platform-team \
        kubernaut.ai/criticality=high \
        kubernaut.ai/sla-tier=tier-1 \
        --overwrite
}

_unlabel_target_node() {
    local node
    for node in $(kubectl get nodes -l kubernaut.ai/managed=true \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
        kubectl label node "$node" \
            kubernaut.ai/managed- \
            kubernaut.ai/environment- \
            kubernaut.ai/business-unit- \
            kubernaut.ai/service-owner- \
            kubernaut.ai/criticality- \
            kubernaut.ai/sla-tier- 2>/dev/null || true
    done
}

run_inject() {
# Label the node running the postgres pod so the Gateway accepts the proactive signal
_label_target_node

POD=$(kubectl get pods -n "${NAMESPACE}" -l app=postgres-emptydir \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
    echo "ERROR: No postgres-emptydir pod found in ${NAMESPACE}"
    exit 1
fi

NODE=$(kubectl get pod "$POD" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}')
echo "==> Target node: ${NODE}"

# ── Dynamic rate calculation based on node filesystem capacity ──────────
# Get disk stats directly from the postgres pod (on the target node).
#
# PrometheusRule: predict_linear(v[3m], 1200) < 0 for 1m
#   W=180s (window), H=1200s (horizon), F=60s (for clause)
#   Desired margin = 480s (8 min -- enough for LLM ~2m + approve + AWX +
#   pg_dump + ArgoCD sync + pg_restore)
#
# Two rate strategies:
#   Case A (window-limited): write fast so the [3m] window is the
#     bottleneck.  Alert fires at W+F=4 min regardless of disk size.
#     R = usable / (W + F + margin)
#     Feasible when R > avail / (W + H)
#
#   Case B (slope-limited): write at the minimum rate that yields the
#     desired margin.  Slower but always feasible.
#     R = threshold / (H - F - margin)
#
# We prefer Case A (faster) and fall back to Case B.

DF_LINE=$(kubectl exec -n "${NAMESPACE}" "${POD}" -- df -B1 / 2>/dev/null | tail -1)
TOTAL_BYTES=$(echo "$DF_LINE" | awk '{print $2}')
AVAIL_BYTES=$(echo "$DF_LINE" | awk '{print $4}')

if [ -z "$TOTAL_BYTES" ] || [ -z "$AVAIL_BYTES" ]; then
    echo "ERROR: Could not read filesystem stats from pod ${POD}"
    exit 1
fi

AVAIL_MB=$(( AVAIL_BYTES / 1048576 ))
TOTAL_MB=$(( TOTAL_BYTES / 1048576 ))
THRESHOLD_MB=$(( TOTAL_MB * 15 / 100 ))  # kubelet default: 15%
USABLE_MB=$(( AVAIL_MB - THRESHOLD_MB ))

if [ "$USABLE_MB" -lt 2048 ]; then
    echo "ERROR: Only ${USABLE_MB} MB usable on ${NODE} (need >= 2048 MB). Free disk first."
    exit 1
fi

# W=180, H=1200, F=60, margin=480  (all in seconds)
# PostgreSQL disk amplification: ~2x (tuple headers, WAL, TOAST)
PG_AMP=2

RATE_MB_S=$(awk "BEGIN {
    avail=${AVAIL_MB}; usable=${USABLE_MB}; threshold=${THRESHOLD_MB}
    W=180; H=1200; F=60; margin=480

    r_fast = usable / (W + F + margin)   # Case A
    r_min  = avail / (W + H)             # min for prediction < 0 during window
    r_slow = threshold / (H - F - margin) # Case B

    if (r_fast > r_min) {
        r = r_fast  # Case A: alert at W+F = 4 min
    } else {
        r = r_slow  # Case B: slower but safe
    }
    if (r < 5) r = 5
    if (r > 60) r = 60   # cap to avoid overwhelming PG I/O
    printf \"%.1f\", r
}")

SLEEP_MS=50
BATCH_SIZE=$(awk "BEGIN { v=int(${RATE_MB_S}*${SLEEP_MS}/1000*1024*${PG_AMP}); if(v<100)v=100; print v }")
ITERATIONS=$(awk "BEGIN { print int(${USABLE_MB}*1024/${BATCH_SIZE})+1000 }")

# Estimate timing (minutes)
EST_ALERT_MIN=$(awk "BEGIN {
    r=${RATE_MB_S}*60; W=3; H=20; F=1
    t_slope = ${AVAIL_MB}/r - H + F
    t_window = W + F
    t = (t_slope > t_window) ? t_slope : t_window
    printf \"%.0f\", t
}")
EST_EVICT_MIN=$(awk "BEGIN { printf \"%.0f\", ${USABLE_MB}/(${RATE_MB_S}*60) }")

echo "==> Injecting fault: dynamic postgres data growth to fill emptyDir..."
echo "  Node:       ${NODE}"
echo "  Disk:       ${TOTAL_MB} MB total, ${AVAIL_MB} MB available"
echo "  Threshold:  ${THRESHOLD_MB} MB (15%), usable: ${USABLE_MB} MB"
echo "  Rate:       ${RATE_MB_S} MB/s (batch=${BATCH_SIZE} rows, sleep=${SLEEP_MS}ms)"
echo "  Iterations: ${ITERATIONS}"
echo "  Estimate:   PredictedDiskPressure at ~${EST_ALERT_MIN} min, eviction at ~${EST_EVICT_MIN} min"
echo ""
echo "  Noise writers:"
echo "    Log-collector: ~3 MB/min unbounded"
echo "    Nginx cache:   ~200 MB burst then stable"
echo "    Redis scratch:  ~100 MB gradual then stable"
echo ""

echo "  Starting postgres continuous data growth..."
kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  psql -U postgres -d postgres -c "CALL simulate_data_growth(${BATCH_SIZE}, ${ITERATIONS}, ${SLEEP_MS});" &

echo ""
echo "  Data growth running in background. Waiting for PredictedDiskPressure..."
echo "  Monitor: kubectl get nodes -o custom-columns='NAME:.metadata.name,DISK_PRESSURE:.status.conditions[?(@.type==\"DiskPressure\")].status'"
echo ""
}

run_monitor() {
echo "==> Pipeline in progress..."
echo ""
echo "  Expected flow (proactive, BR-SP-106):"
echo "    1. PredictedDiskPressure alert fires (predict_linear, before kubelet eviction)"
echo "    2. SP classifies as proactive, normalizes signal to DiskPressure"
echo "    3. HAPI uses proactive prompt (predict & prevent, not RCA)"
echo "    4. AI detects emptyDir antipattern + ArgoCD management"
echo "    5. AI selects MigrateEmptyDirToPVC workflow"
echo "    6. RAR created -- human approval required"
echo "    7. AWX dispatches Ansible playbook (engine=ansible)"
echo "    8. Playbook: cordon -> pg_dump (live!) -> git commit PVC -> ArgoCD sync -> pg_restore -> uncordon"
echo "    9. EA verifies DiskPressure never materialized + DB accessible"
echo ""

if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}"
fi
}

case "$SUBCOMMAND" in
  setup)  run_setup ;;
  inject) run_inject ;;
  all)    run_setup; run_inject; run_monitor ;;
  *)      echo "Usage: $0 [setup|inject|all]"; exit 1 ;;
esac
