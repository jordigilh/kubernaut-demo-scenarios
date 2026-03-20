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
require_infra gitea
require_infra argocd
# shellcheck source=../../scripts/gitops-helper.sh
source "${SCRIPT_DIR}/../../scripts/gitops-helper.sh"

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

# Step 3: Configure webhook for instant sync on push
echo "==> Step 3: Ensuring Gitea webhook notifies ArgoCD on push..."
setup_gitea_argocd_webhook "${GITEA_ADMIN_USER}" "${REPO_NAME}"

# Step 4: Establish baseline
echo ""
echo "==> Step 4: Initial state (healthy):"
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""
}

run_inject() {
# Step 5: Inject failure -- push bad ConfigMap to Gitea
echo "==> Step 5: Injecting failure (bad ConfigMap via Git commit)..."
WORK_DIR=$(mktemp -d)
gitea_connect

cd "${WORK_DIR}"
git clone "${GITEA_GIT_BASE}/${REPO_NAME}.git" repo
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

gitea_disconnect
cd /
rm -rf "${WORK_DIR}"

echo "  Bad commit pushed to Gitea. ArgoCD will sync the broken ConfigMap."
echo ""
}

run_monitor() {
# Step 6: Wait for ArgoCD to sync and pods to crash
echo "==> Step 6: Waiting for ArgoCD to sync and pods to enter CrashLoopBackOff..."
for i in $(seq 1 30); do
    ANNOTATION=$(kubectl get deployment web-frontend -n "${NAMESPACE}" \
      -o jsonpath='{.spec.template.metadata.annotations.kubernaut\.ai/config-version}' 2>/dev/null || echo "")
    if [ "$ANNOTATION" = "broken" ]; then
        echo "  ArgoCD synced broken deployment (attempt $i)."
        break
    fi
    sleep 5
done
sleep 10
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 7: Validate pipeline
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
