#!/usr/bin/env bash
# GitOps Drift Remediation Demo -- Automated Runner
# Scenario #125: Signal != RCA (Pod crash -> ConfigMap is root cause)
#
# Prerequisites:
#   - Kind cluster with overlays/kind/kind-cluster-config.yaml
#   - Gitea and ArgoCD installed (run setup scripts first)
#
# Usage: ./scenarios/gitops-drift/run.sh [setup|inject|all]
#   setup  -- deploy infrastructure, ArgoCD app, and establish healthy baseline
#   inject -- push bad ConfigMap via git (assumes setup already ran)
#   all    -- run full flow (default)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"
require_infra gitea
require_infra argocd

# Ensure the git-revert-v2 workflow is seeded. It depends on gitea-repo-creds,
# which only exists after Gitea is installed. If the initial seed ran before
# Gitea was available, the workflow was skipped (#237).
echo "==> Seeding ActionType CRDs..."
kubectl apply -f "${SCRIPT_DIR}/../../deploy/action-types/" -n "${PLATFORM_NS:-kubernaut-system}" --quiet 2>/dev/null || true
echo "==> Seeding RemediationWorkflow CRDs (namespace: ${PLATFORM_NS:-kubernaut-system})..."
bash "${SCRIPT_DIR}/../../scripts/seed-workflows.sh" --scenario gitops-drift --continue-on-error 2>&1 \
  | grep -E '(Applied|SKIP|ERROR|FAIL|error|git-revert|created)' | sed 's/^/    /'

GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="kubernaut"
GITEA_ADMIN_PASS="kubernaut123"
REPO_NAME="demo-gitops-repo"
NAMESPACE="demo-gitops"

run_setup() {
echo "============================================="
echo " GitOps Drift Remediation Demo (#125)"
echo "============================================="
echo ""

# Step 0: Clean up stale state from any previous run (#245)
# Delete the ArgoCD Application first so selfHeal doesn't fight the
# namespace deletion inside ensure_clean_slate.
kubectl delete -f "${SCRIPT_DIR}/manifests/argocd-application.yaml" \
  --ignore-not-found 2>/dev/null || true

# Revert the Gitea repo to the initial (healthy) commit so that
# run_inject's git-commit is never a no-op (#245).
if kubectl get namespace "${GITEA_NAMESPACE}" &>/dev/null; then
    kill_stale_gitea_pf
    kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http \
      "${GITEA_LOCAL_PORT}:3000" &>/dev/null &
    local pf_pid=$!
    wait_for_port "${GITEA_LOCAL_PORT}"
    local work_dir
    work_dir=$(mktemp -d)
    if timeout 30 git clone \
         "http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@localhost:${GITEA_LOCAL_PORT}/${GITEA_ADMIN_USER}/${REPO_NAME}.git" \
         "${work_dir}/repo" &>/dev/null; then
        cd "${work_dir}/repo"
        local initial_commit current_head
        initial_commit=$(git rev-list --max-parents=0 HEAD 2>/dev/null || echo "")
        current_head=$(git rev-parse HEAD 2>/dev/null || echo "")
        if [ -n "$initial_commit" ] && [ -n "$current_head" ] \
           && [ "$current_head" != "$initial_commit" ]; then
            git reset --hard "$initial_commit" &>/dev/null \
              && git push --force origin main &>/dev/null \
              && echo "  Gitea repo reset to initial commit (${initial_commit:0:7})." \
              || echo "  WARNING: Failed to reset Gitea repo."
        fi
        cd /
    fi
    rm -rf "${work_dir}"
    kill "$pf_pid" 2>/dev/null || true
fi

ensure_clean_slate "${NAMESPACE}"

# Step 1: Apply all manifests (namespace, ArgoCD Application, deployment, PrometheusRule)
echo "==> Step 1: Applying manifests (namespace, ArgoCD Application, deployment, PrometheusRule)..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

echo "==> Step 2: Waiting for ArgoCD to sync and pods to be ready..."
echo "  Waiting for namespace to be created by ArgoCD..."
for i in $(seq 1 60); do
  if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
    break
  fi
  sleep 5
done
kubectl wait --for=condition=Available deployment/web-frontend \
  -n "${NAMESPACE}" --timeout=180s
echo "  web-frontend is healthy."

# Wait for ArgoCD to settle so only one ReplicaSet is active (#245).
# Both kubectl and ArgoCD manage the deployment; ArgoCD may re-apply with
# tracking labels, creating a transient second RS whose pods then disappear.
# If we inject before that settles, the alert fires for the terminated pod
# and the Gateway drops it (correctly) because the pod no longer exists.
echo "  Waiting for ArgoCD to reconcile (single ReplicaSet)..."
local active_rs=0
local rs_elapsed=0
while [ "$rs_elapsed" -lt 120 ]; do
  active_rs=$(kubectl get rs -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | awk '$2 > 0 { n++ } END { print n+0 }')
  if [ "$active_rs" -le 1 ]; then
    break
  fi
  if (( rs_elapsed % 20 == 0 )) && [ "$rs_elapsed" -gt 0 ]; then
    echo "  Still waiting... ${active_rs} active ReplicaSets (${rs_elapsed}s elapsed)"
  fi
  sleep 5
  rs_elapsed=$((rs_elapsed + 5))
done
if [ "$active_rs" -gt 1 ]; then
  echo "  WARNING: ${active_rs} active ReplicaSets after ${rs_elapsed}s — stale alert risk remains."
fi

# Step 3: Establish baseline (let Prometheus scrape healthy metrics)
echo ""
echo "==> Step 3: Establishing healthy baseline (30s)..."
kubectl get pods -n "${NAMESPACE}" -o wide
sleep 30
echo "  Baseline established."
echo ""
}

run_inject() {
# Step 4: Inject failure -- push bad ConfigMap to Gitea
echo "==> Step 4: Injecting failure (bad ConfigMap via Git commit)..."
WORK_DIR=$(mktemp -d)
kill_stale_gitea_pf
kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http "${GITEA_LOCAL_PORT}:3000" &
PF_PID=$!
wait_for_port "${GITEA_LOCAL_PORT}"

cd "${WORK_DIR}"
git clone "http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@localhost:${GITEA_LOCAL_PORT}/${GITEA_ADMIN_USER}/${REPO_NAME}.git" repo
cd repo

# Break the ConfigMap: inject an invalid nginx directive
# Also update the deployment annotation to force a rollout
cat > manifests/configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: demo-gitops
  labels:
    app: web-frontend
data:
  nginx.conf: |
    worker_processes auto;
    error_log /var/log/nginx/error.log warn;
    pid /tmp/nginx.pid;

    events {
        worker_connections 1024;
    }

    http {
        # INVALID: causes nginx to fail on startup
        invalid_directive_that_breaks_nginx on;

        server {
            listen 8080;
            server_name _;

            location / {
                return 200 'healthy\n';
                add_header Content-Type text/plain;
            }

            location /healthz {
                return 200 'ok\n';
                add_header Content-Type text/plain;
            }
        }
    }
EOF

# Also update deployment to force a pod rollout with the new config
cat > manifests/deployment.yaml <<'DEPLOY_EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-frontend
  namespace: demo-gitops
  labels:
    app: web-frontend
    kubernaut.ai/managed: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-frontend
  template:
    metadata:
      labels:
        app: web-frontend
        kubernaut.ai/managed: "true"
      annotations:
        kubernaut.ai/config-version: "broken"
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 3
          periodSeconds: 5
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 3
      volumes:
      - name: config
        configMap:
          name: nginx-config
DEPLOY_EOF

git add .
git config user.email "bad-actor@example.com"
git config user.name "Bad Deploy"
git commit -m "chore: update nginx config (broken value)"
git push origin main

kill "${PF_PID}" 2>/dev/null || true
cd /
rm -rf "${WORK_DIR}"

echo "  Bad commit pushed to Gitea. ArgoCD will sync the broken ConfigMap."
echo ""
}

run_monitor() {
# Step 5: Wait for ArgoCD to sync and pods to crash
echo "==> Step 5: Waiting for ArgoCD to sync and pods to enter CrashLoopBackOff..."
echo "  Gitea webhook notifies ArgoCD on push. Waiting for sync + crash..."
sleep 30
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 6: Validate pipeline
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
