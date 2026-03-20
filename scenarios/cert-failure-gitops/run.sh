#!/usr/bin/env bash
# cert-manager GitOps Demo -- Automated Runner
# Scenario #134: GitOps-managed Certificate failure -> git-based fix
#
# Prerequisites:
#   - Kind cluster with Kubernaut services
#   - cert-manager installed (or run cert-failure scenario first)
#
# Usage: ./scenarios/cert-failure-gitops/run.sh [setup|inject|all]
#   setup  -- deploy CA, GitOps infra, ArgoCD app, and establish healthy baseline
#   inject -- push broken ClusterIssuer via git (assumes setup already ran)
#   all    -- run full flow (default)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-cert-gitops"
GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="kubernaut"
GITEA_ADMIN_PASS="kubernaut123"
REPO_NAME="demo-cert-gitops-repo"

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
require_infra cert-manager
ensure_cert_manager_ocp_monitoring
require_infra gitea
require_infra argocd
# shellcheck source=../../scripts/gitops-helper.sh
source "${SCRIPT_DIR}/../../scripts/gitops-helper.sh"

run_setup() {
echo "============================================="
echo " cert-manager GitOps Failure Demo (#134)"
echo "============================================="
echo ""

# Step 1: Generate self-signed CA
echo "==> Step 1: Generating self-signed CA key pair..."
TMPDIR_CA=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${TMPDIR_CA}/ca.key" -out "${TMPDIR_CA}/ca.crt" \
  -days 365 -subj "/CN=Demo CA/O=Kubernaut"
kubectl create secret tls demo-ca-key-pair \
  --cert="${TMPDIR_CA}/ca.crt" --key="${TMPDIR_CA}/ca.key" \
  -n cert-manager --dry-run=client -o yaml | kubectl apply -f -
rm -rf "${TMPDIR_CA}"

# Step 2: Create Gitea repo with cert-manager manifests
echo "==> Step 2: Pushing cert-manager manifests to Gitea..."
WORK_DIR=$(mktemp -d)
gitea_connect

curl -sk -X POST "${GITEA_API_URL}/api/v1/user/repos" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${REPO_NAME}\", \"auto_init\": true}" -o /dev/null || true

cd "${WORK_DIR}"
git clone "${GITEA_GIT_BASE}/${REPO_NAME}.git" repo
cd repo
git config user.email "kubernaut@kubernaut.ai"
git config user.name "Kubernaut Setup"

mkdir -p manifests

cat > manifests/namespace.yaml <<MANIFEST
apiVersion: v1
kind: Namespace
metadata:
  name: demo-cert-gitops
  labels:
    kubernaut.ai/environment: production
    kubernaut.ai/business-unit: platform
    kubernaut.ai/service-owner: platform-team
    kubernaut.ai/criticality: high
    kubernaut.ai/sla-tier: tier-1
$([ "$PLATFORM" = "ocp" ] && echo '    openshift.io/cluster-monitoring: "true"')
MANIFEST

cat > manifests/clusterissuer.yaml <<'MANIFEST'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: demo-selfsigned-ca-gitops
spec:
  ca:
    secretName: demo-ca-key-pair
MANIFEST

cat > manifests/certificate.yaml <<'MANIFEST'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: demo-app-cert
  namespace: demo-cert-gitops
spec:
  secretName: demo-app-tls
  issuerRef:
    name: demo-selfsigned-ca-gitops
    kind: ClusterIssuer
  dnsNames:
    - demo-app.demo-cert-gitops.svc.cluster.local
    - demo-app
  duration: 2160h
  renewBefore: 360h
MANIFEST

if [ "$PLATFORM" = "ocp" ]; then
    NGINX_IMAGE="nginxinc/nginx-unprivileged:1.27-alpine"
    NGINX_PORT=8443
else
    NGINX_IMAGE="nginx:1.27-alpine"
    NGINX_PORT=443
fi

cat > manifests/deployment.yaml <<MANIFEST
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: demo-cert-gitops
  labels:
    app: demo-app
    kubernaut.ai/managed: "true"
spec:
  replicas: 2
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      containers:
      - name: nginx
        image: ${NGINX_IMAGE}
        ports:
        - containerPort: ${NGINX_PORT}
        volumeMounts:
        - name: tls
          mountPath: /etc/nginx/ssl
          readOnly: true
        resources:
          requests:
            memory: "32Mi"
            cpu: "10m"
          limits:
            memory: "64Mi"
            cpu: "50m"
      volumes:
      - name: tls
        secret:
          secretName: demo-app-tls
          optional: true
---
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: demo-cert-gitops
  labels:
    app: demo-app
    kubernaut.ai/managed: "true"
spec:
  selector:
    app: demo-app
  ports:
  - port: ${NGINX_PORT}
    targetPort: ${NGINX_PORT}
  type: ClusterIP
MANIFEST

git add .
git commit -m "feat: initial cert-manager resources (healthy state)"
git push origin main

gitea_disconnect
cd /
rm -rf "${WORK_DIR}"

# Step 3: Deploy ServiceMonitor, PrometheusRule, and ArgoCD Application
echo "==> Step 3: Applying manifests (ServiceMonitor, PrometheusRule, ArgoCD Application)..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
if [ "$PLATFORM" = "ocp" ]; then
    kubectl label namespace "${NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite
fi
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"
ensure_ocp_namespace_monitoring "${NAMESPACE}"

echo "==> Step 3b: Ensuring Gitea webhook notifies ArgoCD on push..."
setup_gitea_argocd_webhook "${GITEA_ADMIN_USER}" "${REPO_NAME}"

echo "  Waiting for ArgoCD sync..."
for i in $(seq 1 60); do
    if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
        break
    fi
    sleep 5
done

echo "==> Step 4: Waiting for Certificate to become Ready..."
for i in $(seq 1 30); do
  STATUS=$(kubectl get certificate demo-app-cert -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "$STATUS" = "True" ]; then
    echo "  Certificate is Ready."
    break
  fi
  echo "  Attempt $i/30: Certificate status=$STATUS, waiting..."
  sleep 5
done
kubectl get certificate -n "${NAMESPACE}"
echo ""

# Step 5: Baseline
echo "==> Step 5: Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established."
echo ""
}

run_inject() {
# Step 6: Inject failure via git push
echo "==> Step 6: Injecting failure (pushing broken ClusterIssuer via git)..."
WORK_DIR=$(mktemp -d)
gitea_connect

cd "${WORK_DIR}"
git clone "${GITEA_GIT_BASE}/${REPO_NAME}.git" repo
cd repo
git config user.email "bad-actor@example.com"
git config user.name "Bad Deploy"

# Break: change ClusterIssuer to reference a non-existent CA secret
cat > manifests/clusterissuer.yaml <<'MANIFEST'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: demo-selfsigned-ca-gitops
spec:
  ca:
    secretName: nonexistent-ca-secret
MANIFEST

git add .
git commit -m "chore: update CA secret reference (broken)"
git push origin main

gitea_disconnect
cd /
rm -rf "${WORK_DIR}"
echo "  Bad commit pushed. Gitea webhook will notify ArgoCD."

echo "  Waiting for ArgoCD to sync broken ClusterIssuer..."
for i in $(seq 1 90); do
  SECRET_REF=$(kubectl get clusterissuer demo-selfsigned-ca-gitops \
    -o jsonpath='{.spec.ca.secretName}' 2>/dev/null || echo "")
  if [ "$SECRET_REF" = "nonexistent-ca-secret" ]; then
    echo "  ArgoCD synced broken ClusterIssuer (attempt $i)."
    break
  fi
  sleep 5
done

# Delete the original CA secret so cert-manager cannot re-issue even with a
# cached signing key (race between issuer reconciler and certificate issuer).
echo "  Deleting original CA secret to prevent re-issuance..."
kubectl delete secret demo-ca-key-pair -n cert-manager --ignore-not-found

# Restart cert-manager to flush the in-memory CA signing key cache.
echo "  Restarting cert-manager to clear cached signing key..."
kubectl rollout restart deployment cert-manager -n cert-manager
kubectl rollout status deployment cert-manager -n cert-manager --timeout=60s

echo "  Waiting for ClusterIssuer to report Ready=False..."
for i in $(seq 1 30); do
  READY=$(kubectl get clusterissuer demo-selfsigned-ca-gitops \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  if [ "$READY" = "False" ]; then
    echo "  ClusterIssuer is now Ready=False (attempt $i)."
    break
  fi
  sleep 5
done

# Now delete the TLS secret to force re-issuance against the broken issuer
kubectl delete secret demo-app-tls -n "${NAMESPACE}" --ignore-not-found
echo "  TLS secret deleted — cert-manager will fail to re-issue."

echo ""
}

run_monitor() {
echo "==> Step 7: Waiting for pipeline to process alert..."

# Validate pipeline
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
