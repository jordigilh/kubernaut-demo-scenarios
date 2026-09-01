#!/usr/bin/env bash
# GitOps Drift Remediation Demo -- Fleet Hub Steps
#
# Unlike every other scenario's hub.sh (which only confirms an alert),
# this one does most of the scenario's work: Gitea + ArgoCD both run on
# the hub (a real GitOps-hub cluster holds the repo credentials), and
# ArgoCD syncs the web-frontend Application onto the SPOKE as a registered
# remote cluster -- real cross-cluster sync over the wire, not a
# simulation. Run fleet/spoke.sh first (or use ../run.sh, which runs both
# in order for the common single-spoke case) so kube-state-metrics and the
# raw Prometheus rule are in place before pods land there.
#
# This mirrors the topology kubernaut#2326 (RemediationWorkflow.spec.
# execution.clusterId) exists for: target cluster (signal origin) = spoke,
# GitOps-hub/execution cluster = hub. Fleet mode doesn't create a
# WorkflowExecution in alert-only mode though, so that field itself isn't
# exercised here -- this only proves the cross-cluster ArgoCD sync half.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="demo-webui"
GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="kubernaut"
GITEA_ADMIN_PASS="kubernaut123"
REPO_NAME="demo-gitops-repo"

# shellcheck source=../../../scripts/fleet-helper.sh
source "${SCRIPT_DIR}/../../scripts/fleet-helper.sh"
fleet_check_hub_connectivity

# Gitea + ArgoCD both live on the hub; everything below except the spoke
# pod-status checks (kubectl_workload) operates against it via ambient
# kubectl, so point that at the hub for the rest of this script.
export KUBECONFIG="${HUB_KUBECONFIG}"
# shellcheck source=../../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"

echo "==> [hub=${HUB_KUBECONFIG}] Ensuring Gitea + ArgoCD are installed..."
if ! kubectl get deployment gitea -n "${GITEA_NAMESPACE}" &>/dev/null; then
    bash "${SCRIPT_DIR}/../../gitops/scripts/setup-gitea.sh"
fi
ARGOCD_NS=$(get_argocd_namespace)
if ! kubectl get deployment argocd-server -n "${ARGOCD_NS}" &>/dev/null; then
    bash "${SCRIPT_DIR}/../../gitops/scripts/setup-argocd.sh"
fi

echo ""
echo "==> [hub] Registering spoke as a remote ArgoCD cluster..."
SPOKE_SERVER=$(fleet_register_argocd_spoke_cluster "spoke" "${ARGOCD_NS}")
echo "  Spoke registered at ${SPOKE_SERVER}"

echo ""
echo "==> [hub] Deleting any stale Application from a previous run..."
kubectl delete application web-frontend -n "${ARGOCD_NS}" --ignore-not-found

echo ""
echo "==> [hub] Pushing healthy manifests to Gitea repo..."
kill_stale_gitea_pf
kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http "${GITEA_LOCAL_PORT}:3000" &>/dev/null &
PF_PID=$!
wait_for_port "${GITEA_LOCAL_PORT}" 45

curl -sf -X POST "http://localhost:${GITEA_LOCAL_PORT}/api/v1/user/repos" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${REPO_NAME}\", \"auto_init\": true}" -o /dev/null 2>/dev/null || true

WORK_DIR=$(mktemp -d)
cd "${WORK_DIR}"
git init -b main -q
git config user.email "kubernaut@kubernaut.ai"
git config user.name "Kubernaut Setup"
mkdir -p manifests

cat > manifests/namespace.yaml <<NS_EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    kubernaut.ai/managed: "true"
    kubernaut.ai/environment: production
    kubernaut.ai/business-unit: platform
    kubernaut.ai/service-owner: sre-team
    kubernaut.ai/criticality: high
    kubernaut.ai/sla-tier: tier-2
    kubernaut.ai/component: web-frontend
NS_EOF

cat > manifests/configmap.yaml <<CM_EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: ${NAMESPACE}
  labels:
    app: web-frontend
data:
  config.yaml: |
    port: 8080
    routes:
      - path: /
        status: 200
        body: 'healthy'
      - path: /healthz
        status: 200
        body: 'ok'
CM_EOF

cat > manifests/deployment.yaml <<DEPLOY_EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-frontend
  namespace: ${NAMESPACE}
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
      - name: web-frontend
        image: quay.io/kubernaut-cicd/demo-http-server:1.0.0
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: CONFIG_PATH
          value: /etc/demo-http-server/config.yaml
        volumeMounts:
        - name: config
          mountPath: /etc/demo-http-server/config.yaml
          subPath: config.yaml
        resources:
          requests:
            memory: "32Mi"
            cpu: "10m"
          limits:
            memory: "64Mi"
            cpu: "50m"
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
          name: app-config
DEPLOY_EOF

cat > manifests/service.yaml <<SVC_EOF
apiVersion: v1
kind: Service
metadata:
  name: web-frontend
  namespace: ${NAMESPACE}
  labels:
    app: web-frontend
    kubernaut.ai/managed: "true"
    kubernaut.ai/metrics: "true"
spec:
  selector:
    app: web-frontend
  ports:
  - port: 8080
    targetPort: 8080
    name: http
SVC_EOF

git add .
git commit -q -m "Initial deployment: web-frontend with healthy config"
git remote add origin "http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@localhost:${GITEA_LOCAL_PORT}/${GITEA_ADMIN_USER}/${REPO_NAME}.git"
git push -u origin main --force -q
cd /
rm -rf "${WORK_DIR}"
kill "${PF_PID}" 2>/dev/null || true
echo "  Healthy manifests pushed to Gitea."

echo ""
echo "==> [hub] Creating Application (destination: spoke @ ${SPOKE_SERVER})..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: web-frontend
  namespace: ${ARGOCD_NS}
spec:
  project: default
  source:
    repoURL: http://gitea-http.${GITEA_NAMESPACE}:3000/${GITEA_ADMIN_USER}/${REPO_NAME}.git
    targetRevision: HEAD
    path: manifests
  destination:
    server: ${SPOKE_SERVER}
    namespace: ${NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

echo ""
echo "==> [hub] Waiting for ArgoCD to sync and pods to be ready on the spoke..."
echo "  Waiting for the first sync to land the Deployment on the spoke..."
for _i in $(seq 1 24); do
    if kubectl_workload get deployment/web-frontend -n "${NAMESPACE}" &>/dev/null; then
        break
    fi
    sleep 5
done
kubectl_workload wait --for=condition=Available deployment/web-frontend \
  -n "${NAMESPACE}" --timeout=180s
echo "  web-frontend is healthy on the spoke."
kubectl_workload get pods -n "${NAMESPACE}"

echo ""
echo "==> [hub] Establishing healthy baseline (30s)..."
sleep 30
echo "  Baseline established."

echo ""
echo "==> [hub] Injecting failure (bad ConfigMap via Git commit)..."
kill_stale_gitea_pf
kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http "${GITEA_LOCAL_PORT}:3000" &>/dev/null &
PF_PID=$!
wait_for_port "${GITEA_LOCAL_PORT}" 45

WORK_DIR=$(mktemp -d)
cd "${WORK_DIR}"
git clone -q "http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@localhost:${GITEA_LOCAL_PORT}/${GITEA_ADMIN_USER}/${REPO_NAME}.git" repo
cd repo

# Break the ConfigMap: change the listen port from 8080 to 8443. The config
# is valid YAML with a plausible value (HTTPS convention), but the
# container's liveness probe and Service still target 8080, so probes fail
# and k8s kills the pod -- resulting in CrashLoopBackOff.
cat > manifests/configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: ${NAMESPACE}
  labels:
    app: web-frontend
data:
  config.yaml: |
    port: 8443
    routes:
      - path: /
        status: 200
        body: 'healthy'
      - path: /healthz
        status: 200
        body: 'ok'
EOF

# Also update the deployment annotation to force a pod rollout with the
# new config -- rewritten in full (this is the first inject of the run,
# so there's no prior annotation to patch in place).
cat > manifests/deployment.yaml <<DEPLOY_EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-frontend
  namespace: ${NAMESPACE}
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
        kubectl.kubernetes.io/restartedAt: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    spec:
      containers:
      - name: web-frontend
        image: quay.io/kubernaut-cicd/demo-http-server:1.0.0
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: CONFIG_PATH
          value: /etc/demo-http-server/config.yaml
        volumeMounts:
        - name: config
          mountPath: /etc/demo-http-server/config.yaml
          subPath: config.yaml
        resources:
          requests:
            memory: "32Mi"
            cpu: "10m"
          limits:
            memory: "64Mi"
            cpu: "50m"
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
          name: app-config
DEPLOY_EOF

git add .
git config user.email "bad-actor@example.com"
git config user.name "Bad Deploy"
git commit -q -m "chore: migrate app port to 8443 for TLS termination"
git push -q origin main
cd /
rm -rf "${WORK_DIR}"
kill "${PF_PID}" 2>/dev/null || true
echo "  Bad commit pushed. ArgoCD will sync the broken ConfigMap onto the spoke."

echo ""
echo "==> [hub] Forcing ArgoCD refresh..."
kubectl annotate application web-frontend -n "${ARGOCD_NS}" \
  argocd.argoproj.io/refresh=hard --overwrite

echo ""
echo "==> [hub] Waiting for the spoke pods to crash..."
sleep 30
kubectl_workload get pods -n "${NAMESPACE}"

echo ""
echo "==> [hub] Waiting for alert..."
fleet_wait_for_alert "KubePodCrashLooping" "${NAMESPACE}" 300
echo ""
echo "==> Alert is firing. Fleet mode stops here (alert-only)."
echo "    This topology (signal on spoke, GitOps-hub on hub) is exactly the"
echo "    case kubernaut#2326's RemediationWorkflow.spec.execution.clusterId"
echo "    was added for -- the git-revert-v2 workflow's Job should run here"
echo "    on the hub (it holds the Gitea credentials), not the spoke. Fleet"
echo "    mode doesn't create a WorkflowExecution in alert-only mode, so"
echo "    that field itself isn't exercised by this script; this only"
echo "    proves the cross-cluster ArgoCD sync half of the topology."
