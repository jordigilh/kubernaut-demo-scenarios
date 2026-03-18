#!/usr/bin/env bash
# Deploy Gitea (lightweight Git server) for GitOps demo scenarios.
# Uses Helm chart with SQLite backend (minimal memory footprint ~200-300MB).
#
# Platform-aware:
#   Kind  — standard Helm install
#   OCP   — adds restricted-v2 compatible securityContext values and creates a Route
#
# Usage: ./scenarios/gitops/scripts/setup-gitea.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../../scripts/platform-helper.sh"

GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="kubernaut"
GITEA_ADMIN_PASS="kubernaut123"
REPO_NAME="demo-gitops-repo"

echo "==> Installing Gitea in namespace ${GITEA_NAMESPACE} (platform: ${PLATFORM})..."

kubectl create namespace "${GITEA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

helm repo add gitea-charts https://dl.gitea.com/charts/ 2>/dev/null || true
helm repo update gitea-charts

OCP_VALUES=()
if [ "$PLATFORM" = "ocp" ]; then
    OCP_VALUES=(
        --set "containerSecurityContext.allowPrivilegeEscalation=false"
        --set "containerSecurityContext.runAsNonRoot=true"
        --set "containerSecurityContext.capabilities.drop={ALL}"
        --set "containerSecurityContext.seccompProfile.type=RuntimeDefault"
    )
    echo "  Adding OCP-compatible securityContext values."
fi

helm upgrade --install gitea gitea-charts/gitea \
  --namespace "${GITEA_NAMESPACE}" \
  --set gitea.admin.username="${GITEA_ADMIN_USER}" \
  --set gitea.admin.password="${GITEA_ADMIN_PASS}" \
  --set gitea.admin.email="admin@kubernaut.ai" \
  --set persistence.enabled=false \
  --set "gitea.config.database.DB_TYPE=sqlite3" \
  --set postgresql.enabled=false \
  --set postgresql-ha.enabled=false \
  --set redis-cluster.enabled=false \
  --set "resources.requests.memory=128Mi" \
  --set "resources.requests.cpu=50m" \
  --set "resources.limits.memory=512Mi" \
  --set "resources.limits.cpu=500m" \
  "${OCP_VALUES[@]}" \
  --wait --timeout=300s

echo "==> Waiting for Gitea pod to be ready..."
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=gitea \
  -n "${GITEA_NAMESPACE}" --timeout=120s

# ── Determine Gitea URL for API access ───────────────────────────────────────

GITEA_API_URL=""
PF_PID=""

_cleanup_pf() {
    [ -n "${PF_PID}" ] && kill "${PF_PID}" 2>/dev/null || true
}
trap _cleanup_pf EXIT

if [ "$PLATFORM" = "ocp" ]; then
    if ! kubectl get route gitea-http -n "${GITEA_NAMESPACE}" &>/dev/null; then
        echo "==> Creating OpenShift Route for Gitea..."
        kubectl create route edge gitea-http \
            --service=gitea-http --port=http \
            -n "${GITEA_NAMESPACE}" 2>/dev/null || true
    fi
    ROUTE_HOST=$(kubectl get route gitea-http -n "${GITEA_NAMESPACE}" \
        -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -n "${ROUTE_HOST}" ]; then
        GITEA_API_URL="https://${ROUTE_HOST}"
        echo "  Route: ${GITEA_API_URL}"
    fi
fi

if [ -z "${GITEA_API_URL}" ]; then
    kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http 3000:3000 &
    PF_PID=$!
    sleep 3
    GITEA_API_URL="http://localhost:3000"
fi

# ── Create repository ────────────────────────────────────────────────────────

echo "==> Creating repository via Gitea API..."
curl -sf -X POST "${GITEA_API_URL}/api/v1/user/repos" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${REPO_NAME}\", \"auto_init\": false, \"private\": false}" \
  -o /dev/null 2>/dev/null || echo "  Repository may already exist"

# ── Push initial manifests ───────────────────────────────────────────────────

echo "==> Pushing initial manifests to Gitea..."
WORK_DIR=$(mktemp -d)
cd "${WORK_DIR}"
git init
git config user.email "kubernaut@kubernaut.ai"
git config user.name "Kubernaut Setup"

mkdir -p manifests

cat > manifests/namespace.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: demo-gitops
  labels:
    kubernaut.ai/environment: staging
    kubernaut.ai/business-unit: platform
    kubernaut.ai/service-owner: sre-team
    kubernaut.ai/criticality: high
    kubernaut.ai/sla-tier: tier-2
EOF

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

cat > manifests/deployment.yaml <<'EOF'
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
EOF

cat > manifests/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: web-frontend
  namespace: demo-gitops
  labels:
    app: web-frontend
    kubernaut.ai/managed: "true"
spec:
  selector:
    app: web-frontend
  ports:
  - port: 8080
    targetPort: 8080
EOF

git add .
git commit -m "Initial deployment: nginx web-frontend with healthy config"

# Push via port-forward or Route
GIT_PUSH_URL="${GITEA_API_URL}/${GITEA_ADMIN_USER}/${REPO_NAME}.git"
if [ -n "${PF_PID}" ]; then
    GIT_PUSH_URL="http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@localhost:3000/${GITEA_ADMIN_USER}/${REPO_NAME}.git"
else
    GIT_PUSH_URL="${GITEA_API_URL}/${GITEA_ADMIN_USER}/${REPO_NAME}.git"
    git config http.sslVerify false
fi
git remote add origin "${GIT_PUSH_URL}"
git push -u origin main --force

cd /
rm -rf "${WORK_DIR}"

GITEA_CLUSTER_URL="http://gitea-http.${GITEA_NAMESPACE}:3000"
echo "==> Gitea setup complete (platform: ${PLATFORM})"
echo "    URL (in-cluster): ${GITEA_CLUSTER_URL}"
echo "    Repo: ${GITEA_CLUSTER_URL}/${GITEA_ADMIN_USER}/${REPO_NAME}"
if [ "$PLATFORM" = "ocp" ] && [ -n "${ROUTE_HOST:-}" ]; then
    echo "    Route: https://${ROUTE_HOST}"
fi
