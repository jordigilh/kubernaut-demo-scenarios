#!/usr/bin/env bash
# DiskPressure emptyDir Migration Demo -- Automated Runner
# Scenario #324: PostgreSQL on emptyDir fills disk -> DiskPressure ->
# LLM detects antipattern -> RAR -> Ansible backs up DB, commits PVC migration
# to Git -> ArgoCD syncs -> restore -> EA verifies
#
# Flagship enterprise demo: LLM + RAR + Ansible/AAP + GitOps + audit trail
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

run_setup() {
echo "============================================="
echo " DiskPressure emptyDir Migration Demo (#324)"
echo " emptyDir growth -> DiskPressure -> Ansible/AWX"
echo " -> GitOps PVC migration -> DB restore"
echo "============================================="
echo ""

# Step 1: Push deployment YAML to Gitea repo
echo "==> Step 1: Pushing deployment manifests to Gitea..."
WORK_DIR=$(mktemp -d)
kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3

curl -s -X POST "http://localhost:3000/api/v1/user/repos" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${REPO_NAME}\", \"auto_init\": true}" -o /dev/null 2>/dev/null || true

cd "${WORK_DIR}"
git clone "http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@localhost:3000/${GITEA_ADMIN_USER}/${REPO_NAME}.git" repo 2>/dev/null
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

cat > disk-pressure-emptydir/kustomization.yaml <<'MANIFEST'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
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

kill "${PF_PID}" 2>/dev/null || true
cd /
rm -rf "${WORK_DIR}"

# Step 2: Apply all manifests (namespace, Prometheus rule, ArgoCD Application)
echo "==> Step 2: Applying manifests (namespace, Prometheus rule, ArgoCD Application)..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Speed up ArgoCD polling for demo
ARGOCD_NS=$(get_argocd_namespace)
kubectl patch configmap argocd-cm -n "${ARGOCD_NS}" --type merge \
  -p '{"data":{"timeout.reconciliation":"60s"}}' 2>/dev/null || true

# Step 3: Wait for ArgoCD sync and PostgreSQL readiness
echo "==> Step 3: Waiting for ArgoCD sync..."
for i in $(seq 1 60); do
    if kubectl get deployment postgres-emptydir -n "${NAMESPACE}" &>/dev/null; then
        echo "  ArgoCD synced deployment (attempt ${i})."
        break
    fi
    sleep 5
done

echo "==> Step 4: Waiting for PostgreSQL readiness..."
kubectl wait --for=condition=Available deployment/postgres-emptydir \
  -n "${NAMESPACE}" --timeout=180s
echo "  PostgreSQL is running with emptyDir storage."
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
        echo "WARNING: could not determine target node for DiskPressure signal"
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
# Label the node running the postgres pod so the Gateway accepts the DiskPressure signal
_label_target_node

echo "==> Injecting fault: calling simulate_data_growth() to fill emptyDir..."
echo "  This generates ~100 MB of data per call (500 rows x 200 iterations x ~1KB/row)."
echo "  On a node with tight disk thresholds, DiskPressure will trigger."
echo ""

POD=$(kubectl get pods -n "${NAMESPACE}" -l app=postgres-emptydir \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD" ]; then
    echo "ERROR: No postgres-emptydir pod found in ${NAMESPACE}"
    exit 1
fi

# Run data growth in a loop -- each call adds ~100 MB.
# Adjust iterations based on available node disk.
for round in 1 2 3 4 5; do
    echo "  Round ${round}/5: inserting batch..."
    kubectl exec -n "${NAMESPACE}" "${POD}" -- \
      psql -U postgres -d postgres -c "CALL simulate_data_growth(500, 200, 50);" &
done

echo ""
echo "  Data growth running in background. Waiting for DiskPressure..."
echo "  Monitor: kubectl get nodes -o custom-columns='NAME:.metadata.name,DISK_PRESSURE:.status.conditions[?(@.type==\"DiskPressure\")].status'"
echo ""
}

run_monitor() {
echo "==> Pipeline in progress..."
echo ""
echo "  Expected flow:"
echo "    1. KubeNodeDiskPressure alert fires"
echo "    2. AI Analysis detects emptyDir antipattern + ArgoCD management"
echo "    3. AI selects MigrateEmptyDirToPVC (not DeletePod/RestartPod)"
echo "    4. RAR created -- human approval required"
echo "    5. AWX dispatches Ansible playbook (engine=ansible)"
echo "    6. Playbook: cordon -> pg_dump -> git commit PVC -> ArgoCD sync -> pg_restore -> uncordon"
echo "    7. EA verifies DiskPressure resolved + DB accessible"
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
