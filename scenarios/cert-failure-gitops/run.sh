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
require_infra gitea
require_infra argocd

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

# Speed up ArgoCD polling for demo scenarios (default 180s -> 60s)
kubectl patch configmap argocd-cm -n argocd --type merge \
  -p '{"data":{"timeout.reconciliation":"60s"}}' 2>/dev/null || true

# Step 3: Create Gitea repo with cert-manager manifests
echo "==> Step 4: Pushing cert-manager manifests to Gitea..."
WORK_DIR=$(mktemp -d)
kill_stale_gitea_pf
kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http "${GITEA_LOCAL_PORT}:3000" &
PF_PID=$!
wait_for_port "${GITEA_LOCAL_PORT}"

# Create repo in Gitea
curl -s -X POST "http://localhost:${GITEA_LOCAL_PORT}/api/v1/user/repos" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${REPO_NAME}\", \"auto_init\": true}" -o /dev/null || true

cd "${WORK_DIR}"
git clone "http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@localhost:${GITEA_LOCAL_PORT}/${GITEA_ADMIN_USER}/${REPO_NAME}.git" repo
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
    kubernaut.ai/managed: "true"
    kubernaut.ai/environment: production
    kubernaut.ai/business-unit: platform
    kubernaut.ai/service-owner: platform-team
    kubernaut.ai/criticality: high
    kubernaut.ai/sla-tier: tier-1
$([ "$PLATFORM" = "ocp" ] && echo '    openshift.io/cluster-monitoring: "true"')
$([ "$PLATFORM" = "ocp" ] && echo '    argocd.argoproj.io/managed-by: openshift-gitops')
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
if ! git diff --cached --quiet; then
  git commit -m "feat: initial cert-manager resources (healthy state)"
  git push origin main
else
  echo "  Manifests already in repo (idempotent). Skipping commit."
fi

kill "${PF_PID}" 2>/dev/null || true
cd /
rm -rf "${WORK_DIR}"

# Step 5: Deploy ServiceMonitor, PrometheusRule, and ArgoCD Application
echo "==> Step 5: Applying manifests (ServiceMonitor, PrometheusRule, ArgoCD Application)..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
if [ "$PLATFORM" = "ocp" ]; then
    kubectl label namespace "${NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite
    kubectl label namespace "${NAMESPACE}" argocd.argoproj.io/managed-by=openshift-gitops --overwrite
    # Label cert-manager namespace so its ServiceMonitor is scraped by cluster
    # Prometheus (same instance evaluating the PrometheusRule in demo-cert-gitops).
    # Without this, cert-manager metrics go to user-workload Prometheus and the
    # alert rule in cluster Prometheus never fires (#290).
    # NOTE: This moves ALL ServiceMonitors in cert-manager ns to cluster Prometheus.
    # cleanup.sh removes this label to restore the original state.
    kubectl label namespace cert-manager openshift.io/cluster-monitoring=true --overwrite
    echo "  Labeled cert-manager namespace for cluster Prometheus scraping."
fi
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

echo "  Waiting for ArgoCD sync..."
sleep 15

if [ "$PLATFORM" = "ocp" ]; then
    echo "  Waiting for cluster Prometheus to scrape cert-manager metrics..."
    for i in $(seq 1 12); do
        if kubectl get --raw "/api/v1/namespaces/openshift-monitoring/services/prometheus-k8s:web/proxy/api/v1/query?query=certmanager_certificate_ready_status" 2>/dev/null \
           | grep -q '"result":\[{'; then
            echo "  cert-manager metrics available in cluster Prometheus (attempt $i)."
            break
        fi
        [ "$i" -eq 12 ] && echo "  WARNING: cert-manager metrics not yet visible after 60s. Proceeding anyway."
        sleep 5
    done
fi

echo "==> Step 6: Waiting for Certificate to become Ready..."
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

# Step 7: Baseline
echo "==> Step 7: Establishing healthy baseline (20s)..."
sleep 20
echo "  Baseline established."
echo ""
}

run_inject() {
# Step 8: Inject failure via git push
echo "==> Step 8: Injecting failure (pushing broken ClusterIssuer via git)..."
WORK_DIR=$(mktemp -d)
kill_stale_gitea_pf
kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http "${GITEA_LOCAL_PORT}:3000" &
PF_PID=$!
wait_for_port "${GITEA_LOCAL_PORT}"

cd "${WORK_DIR}"
git clone "http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@localhost:${GITEA_LOCAL_PORT}/${GITEA_ADMIN_USER}/${REPO_NAME}.git" repo
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

kill "${PF_PID}" 2>/dev/null || true
cd /
rm -rf "${WORK_DIR}"
echo "  Bad commit pushed. ArgoCD will sync broken ClusterIssuer."

# Force ArgoCD to refresh immediately instead of waiting for the next poll cycle.
kubectl annotate application demo-cert-gitops -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true

# Wait for ArgoCD to sync the broken commit.
echo "  Waiting for ArgoCD to sync broken ClusterIssuer..."
for i in $(seq 1 90); do
  SECRET_REF=$(kubectl get clusterissuer demo-selfsigned-ca-gitops \
    -o jsonpath='{.spec.ca.secretName}' 2>/dev/null || echo "")
  if [ "$SECRET_REF" = "nonexistent-ca-secret" ]; then
    echo "  ArgoCD synced broken ClusterIssuer (attempt $i)."
    break
  fi
  if [ $((i % 12)) -eq 0 ]; then
    echo "  Still waiting... (attempt $i, re-triggering refresh)"
    kubectl annotate application demo-cert-gitops -n argocd \
      argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true
  fi
  sleep 5
done

# Wait for ClusterIssuer to report Ready=False (the broken reference to
# nonexistent-ca-secret is sufficient — no need to delete the real CA secret,
# which would prevent the git revert path from fully restoring the Certificate).
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

# Delete the TLS secret to force re-issuance against the broken issuer.
# The CA secret (demo-ca-key-pair) is intentionally left intact so that the
# git revert path can fully restore certificate issuance.
kubectl delete secret demo-app-tls -n "${NAMESPACE}" --ignore-not-found
echo "  TLS secret deleted — cert-manager will fail to re-issue."

echo ""
}

run_monitor() {
echo "==> Step 9: Waiting for pipeline to process alert..."

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
