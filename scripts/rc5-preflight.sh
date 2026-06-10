#!/usr/bin/env bash
# rc5-preflight.sh — Comprehensive preflight check for parallel OCP validation.
#
# Verifies all infrastructure dependencies, shared platform state, AAP config,
# and Gitea-ArgoCD webhook before launching scenario groups. Exits non-zero on
# any blocking failure.
#
# Usage:
#   bash scripts/rc5-preflight.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"

# shellcheck source=platform-helper.sh
source "${SCRIPT_DIR}/platform-helper.sh"
# shellcheck source=monitoring-helper.sh
source "${SCRIPT_DIR}/monitoring-helper.sh"

AAP_NAMESPACE="${AAP_NAMESPACE:-aap}"
AAP_INSTANCE_NAME="${AAP_INSTANCE_NAME:-kubernaut-controller}"
GITEA_NAMESPACE="gitea"
GITEA_ADMIN_USER="kubernaut"
GITEA_ADMIN_PASS="kubernaut123"

FAILED=()
WARNED=()

_pass() { echo "  [PASS] $1"; }
_fail() { echo "  [FAIL] $1"; FAILED+=("$1"); }
_warn() { echo "  [WARN] $1"; WARNED+=("$1"); }

echo "============================================="
echo " RC5 Parallel Validation — Preflight Check"
echo "============================================="
echo ""

# ── 1. Cluster + Platform ────────────────────────────────────────────────────

echo "==> 1. Cluster and Kubernaut platform..."
if require_demo_ready 2>&1 | tail -5; then
    _pass "Cluster healthy, Kubernaut installed, workflows seeded"
else
    _fail "require_demo_ready failed — cluster or platform not ready"
fi
echo ""

# ── 2. Prometheus toolset ────────────────────────────────────────────────────

echo "==> 2. Prometheus toolset..."
if enable_prometheus_toolset 2>&1 | tail -3; then
    _pass "Prometheus toolset enabled"
else
    _fail "enable_prometheus_toolset failed"
fi
echo ""

# ── 3. Production approval policy ────────────────────────────────────────────

echo "==> 3. Production approval policy..."
if force_production_approval 2>&1 | tail -3; then
    _pass "Production approval policy enforced"
else
    _fail "force_production_approval failed"
fi
echo ""

# ── 4. Infrastructure dependencies ───────────────────────────────────────────

echo "==> 4. Infrastructure dependencies..."

check_infra() {
    local component="$1" needed_by="$2" severity="${3:-fail}"
    if (require_infra "$component") &>/dev/null; then
        _pass "$component (needed by: $needed_by)"
    elif [ "$severity" = "warn" ]; then
        _warn "$component not available — scenarios will be skipped: $needed_by"
    else
        _fail "$component not available (needed by: $needed_by)"
    fi
}

check_infra "metrics-server"  "autoscale, hpa-maxed"
check_infra "cert-manager"    "cert-failure"
check_infra "istio"           "mesh-routing-failure"       "warn"
check_infra "awx"             "disk-pressure-emptydir"     "warn"
check_infra "awx-engine"      "disk-pressure-emptydir"     "warn"
check_infra "gitea"           "gitops-drift, disk-pressure-emptydir" "warn"
check_infra "argocd"          "disk-pressure-emptydir"     "warn"
echo ""

# ── 5. AAP WE internal service URL ───────────────────────────────────────────
# The operator reconciles the Kubernaut CR and generates the WE ConfigMap.
# We only verify the CR has the ansible section with an internal service URL
# pointing at the AAP controller — we never patch the ConfigMap directly.

echo "==> 5. WE controller AAP API URL..."
CR_AAP_URL=$(kubectl get kubernaut -n "${PLATFORM_NS}" \
    -o jsonpath='{.items[0].spec.ansible.apiURL}' 2>/dev/null || true)
CR_AAP_ENABLED=$(kubectl get kubernaut -n "${PLATFORM_NS}" \
    -o jsonpath='{.items[0].spec.ansible.enabled}' 2>/dev/null || true)
AAP_SVC_HOST="${AAP_INSTANCE_NAME}-service.${AAP_NAMESPACE}"

if [ -z "$CR_AAP_URL" ]; then
    _warn "No ansible.apiURL found in Kubernaut CR — AAP-dependent scenarios will be skipped"
elif [ "$CR_AAP_ENABLED" != "true" ]; then
    _warn "Ansible executor not enabled in Kubernaut CR (enabled=$CR_AAP_ENABLED)"
elif echo "$CR_AAP_URL" | grep -q "$AAP_SVC_HOST"; then
    _pass "CR ansible.apiURL uses internal service: $CR_AAP_URL"
else
    _warn "CR ansible.apiURL='$CR_AAP_URL' does not point to internal service '$AAP_SVC_HOST'"
fi
echo ""

# ── 6. AAP job template credentials ──────────────────────────────────────────

echo "==> 6. AAP job template credentials..."
AAP_SVC=$(kubectl get svc -n "$AAP_NAMESPACE" -o name 2>/dev/null \
    | grep -m1 'controller-service' | sed 's|^service/||' || true)

if [ -z "$AAP_SVC" ]; then
    _warn "AAP controller service not found in ${AAP_NAMESPACE} — skipping credential check"
else
    AAP_PASS=$(kubectl get secret -n "$AAP_NAMESPACE" \
        -l app.kubernetes.io/component=automationcontroller \
        -o jsonpath='{.items[0].data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ -z "$AAP_PASS" ]; then
        AAP_PASS=$(kubectl get secret "${AAP_SVC%-service}-admin-password" -n "$AAP_NAMESPACE" \
            -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi

    if [ -z "$AAP_PASS" ]; then
        _warn "Could not retrieve AAP admin password — skipping credential check"
    else
        PF_PORT=18053
        kubectl port-forward -n "$AAP_NAMESPACE" "svc/${AAP_SVC}" "${PF_PORT}:80" &>/dev/null &
        PF_PID=$!
        sleep 3

        TEMPLATES=$(curl -sf "http://localhost:${PF_PORT}/api/v2/job_templates/" \
            -u "admin:${AAP_PASS}" 2>/dev/null || true)

        if [ -z "$TEMPLATES" ]; then
            _warn "Could not query AAP API — skipping credential check"
        else
            TMPL_IDS=$(echo "$TEMPLATES" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for t in d.get('results', []):
    if 'migrate' in t.get('name','').lower() or 'memory' in t.get('name','').lower():
        print(t['id'])
" 2>/dev/null || true)

            ANY_MISSING=false
            for tmpl_id in $TMPL_IDS; do
                CREDS=$(curl -sf "http://localhost:${PF_PORT}/api/v2/job_templates/${tmpl_id}/credentials/" \
                    -u "admin:${AAP_PASS}" 2>/dev/null || true)
                [ -z "$CREDS" ] && continue

                TMPL_NAME=$(echo "$TEMPLATES" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for t in d.get('results', []):
    if t['id'] == ${tmpl_id}:
        print(t['name']); break
" 2>/dev/null || echo "template-${tmpl_id}")

                HAS_K8S=$(echo "$CREDS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('yes' if any(c.get('credential_type') in (17, 18) for c in d.get('results',[])) else 'no')
" 2>/dev/null || echo "unknown")
                HAS_GITEA=$(echo "$CREDS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('yes' if any('gitea' in c.get('name','').lower() for c in d.get('results',[])) else 'no')
" 2>/dev/null || echo "unknown")

                if [ "$HAS_K8S" = "no" ] || [ "$HAS_GITEA" = "no" ]; then
                    _warn "AAP template '${TMPL_NAME}' missing creds (K8s=${HAS_K8S}, Gitea=${HAS_GITEA}). Fix: bash scripts/aap-helper.sh --configure-only"
                    ANY_MISSING=true
                fi
            done

            if [ "$ANY_MISSING" = false ] && [ -n "$TMPL_IDS" ]; then
                _pass "AAP job template credentials verified"
            fi
        fi

        kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null || true
    fi
fi
echo ""

# ── 7. Gitea-to-ArgoCD webhook ───────────────────────────────────────────────

echo "==> 7. Gitea-to-ArgoCD webhook..."
GITEA_POD=$(kubectl get pods -n "${GITEA_NAMESPACE}" -l app.kubernetes.io/name=gitea \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$GITEA_POD" ]; then
    _warn "Gitea pod not found — skipping webhook check"
else
    ARGOCD_NS=$(get_argocd_namespace)
    if [ "$PLATFORM" = "ocp" ]; then
        ARGOCD_WH_URL="https://openshift-gitops-server.${ARGOCD_NS}.svc/api/webhook"
    else
        ARGOCD_WH_URL="https://argocd-server.${ARGOCD_NS}.svc/api/webhook"
    fi

    # Ensure SKIP_TLS_VERIFY on OCP
    if [ "${PLATFORM:-}" = "ocp" ]; then
        CURRENT_WH_CFG=$(kubectl get secret gitea-inline-config -n "${GITEA_NAMESPACE}" \
            -o jsonpath='{.data.webhook}' 2>/dev/null | base64 -d 2>/dev/null || true)
        if ! echo "$CURRENT_WH_CFG" | grep -q "SKIP_TLS_VERIFY"; then
            kubectl patch secret gitea-inline-config -n "${GITEA_NAMESPACE}" --type=merge \
                -p '{"stringData":{"webhook":"SKIP_TLS_VERIFY=true\nALLOWED_HOST_LIST=*"}}' 2>/dev/null
            kubectl rollout restart deployment/gitea -n "${GITEA_NAMESPACE}" 2>/dev/null
            kubectl rollout status deployment/gitea -n "${GITEA_NAMESPACE}" --timeout=120s 2>/dev/null
            _pass "Gitea SKIP_TLS_VERIFY configured for OCP"
            GITEA_POD=$(kubectl get pods -n "${GITEA_NAMESPACE}" -l app.kubernetes.io/name=gitea \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        else
            _pass "Gitea SKIP_TLS_VERIFY already configured"
        fi
    fi

    # Check webhook on known repos
    TOKEN_NAME="preflight-wh-$$"
    GITEA_TOKEN=$(kubectl exec -n "${GITEA_NAMESPACE}" "${GITEA_POD}" -- \
        gitea admin user generate-access-token \
        -u "${GITEA_ADMIN_USER}" -t "${TOKEN_NAME}" \
        --scopes all --raw 2>/dev/null) || true

    if [ -z "$GITEA_TOKEN" ]; then
        _warn "Could not create Gitea token — skipping webhook check"
    else
        WEBHOOK_OK=true
        for REPO in kubernaut-manifests disk-pressure-manifests; do
            HOOKS=$(kubectl exec -n "${GITEA_NAMESPACE}" "${GITEA_POD}" -- \
                wget -q -O - \
                --header="Authorization: token ${GITEA_TOKEN}" \
                "http://localhost:3000/api/v1/repos/${GITEA_ADMIN_USER}/${REPO}/hooks" 2>/dev/null || echo "[]")

            HAS_ARGOCD_HOOK=$(echo "$HOOKS" | python3 -c "
import json, sys
try:
    hooks = json.load(sys.stdin)
    print('yes' if any('/api/webhook' in h.get('config',{}).get('url','') for h in hooks) else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")

            if [ "$HAS_ARGOCD_HOOK" = "yes" ]; then
                _pass "Webhook registered for repo ${REPO}"
            else
                # Repo might not exist yet (created by run.sh); only warn
                REPO_EXISTS=$(kubectl exec -n "${GITEA_NAMESPACE}" "${GITEA_POD}" -- \
                    wget -q -O /dev/null --spider \
                    --header="Authorization: token ${GITEA_TOKEN}" \
                    "http://localhost:3000/api/v1/repos/${GITEA_ADMIN_USER}/${REPO}" 2>&1 && echo "yes" || echo "no")
                if [ "$REPO_EXISTS" = "yes" ]; then
                    _warn "No ArgoCD webhook on repo ${REPO} — scenario run.sh will create it"
                else
                    _pass "Repo ${REPO} does not exist yet (created by scenario run.sh)"
                fi
            fi
        done

        # Clean up the token
        kubectl exec -n "${GITEA_NAMESPACE}" "${GITEA_POD}" -- \
            gitea admin user delete-access-token \
            -u "${GITEA_ADMIN_USER}" -t "${TOKEN_NAME}" 2>/dev/null || true
    fi
fi
echo ""

# ── 7b. Gitea port-forward smoke test ────────────────────────────────────────
# Scenarios like gitops-drift use kubectl port-forward to push git commits.
# Validate that a port-forward to Gitea HTTP actually works so failures are
# caught here instead of mid-scenario.

echo "==> 7b. Gitea port-forward smoke test (port ${GITEA_LOCAL_PORT})..."
# Kill any stale port-forward on our port first
kill_stale_gitea_pf 2>/dev/null || true

kubectl port-forward -n "${GITEA_NAMESPACE}" svc/gitea-http \
    "${GITEA_LOCAL_PORT}:3000" &>/dev/null &
_PF_PID=$!

_PF_READY=false
for _i in $(seq 1 30); do
    if curl -sf "http://localhost:${GITEA_LOCAL_PORT}" >/dev/null 2>&1; then
        _PF_READY=true
        break
    fi
    sleep 1
done

kill "$_PF_PID" 2>/dev/null || true
wait "$_PF_PID" 2>/dev/null || true

if [ "$_PF_READY" = "true" ]; then
    _pass "Gitea port-forward on localhost:${GITEA_LOCAL_PORT} responds"
else
    _warn "Gitea port-forward on localhost:${GITEA_LOCAL_PORT} not ready after 30s (gitops-drift, disk-pressure-emptydir will be skipped)"
fi
echo ""

# ── 8. Stale node taints and labels ───────────────────────────────────────────

echo "==> 8. Stale node taints from previous scenario runs..."
STALE_TAINTS=$(kubectl get nodes -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
stale = []
scenario_keys = {'scenario', 'maintenance', 'disk-pressure'}
for node in data.get('items', []):
    name = node['metadata']['name']
    for taint in node.get('spec', {}).get('taints', []):
        key = taint.get('key', '')
        if key in scenario_keys or key.startswith('scenario'):
            stale.append(f\"{name}: {key}={taint.get('value','')}:{taint.get('effect','')}\")
for s in stale:
    print(s)
" 2>/dev/null || true)

if [ -n "$STALE_TAINTS" ]; then
    echo "  Found stale scenario taints — removing:"
    while IFS= read -r line; do
        echo "    $line"
        NODE=$(echo "$line" | cut -d: -f1)
        TAINT_KEY=$(echo "$line" | cut -d' ' -f2 | cut -d= -f1)
        kubectl taint node "$NODE" "${TAINT_KEY}-" 2>/dev/null || true
    done <<< "$STALE_TAINTS"
    _pass "Stale scenario taints removed"
else
    _pass "No stale scenario taints on nodes"
fi

STALE_LABELS=$(kubectl get nodes -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
stale = []
label_keys = {'kubernaut.ai/workload-pool', 'scenario'}
for node in data.get('items', []):
    name = node['metadata']['name']
    labels = node.get('metadata', {}).get('labels', {})
    for key in label_keys:
        if key in labels:
            stale.append(f\"{name}: {key}={labels[key]}\")
for s in stale:
    print(s)
" 2>/dev/null || true)

if [ -n "$STALE_LABELS" ]; then
    echo "  Found stale scenario labels — removing:"
    while IFS= read -r line; do
        echo "    $line"
        NODE=$(echo "$line" | cut -d: -f1)
        LABEL_KEY=$(echo "$line" | cut -d' ' -f2 | cut -d= -f1)
        kubectl label node "$NODE" "${LABEL_KEY}-" 2>/dev/null || true
    done <<< "$STALE_LABELS"
    _pass "Stale scenario labels removed"
else
    _pass "No stale scenario labels on nodes"
fi
echo ""

# ── 9. Node disk usage ────────────────────────────────────────────────────────

echo "==> 9. Node disk usage..."
DISK_THRESHOLD=${DISK_THRESHOLD:-90}
DISK_ISSUES=false

WORKER_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
if [ -z "$WORKER_NODES" ]; then
    WORKER_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -v 'control-plane\|master' | awk '{print $1}')
fi

for NODE in $WORKER_NODES; do
    MCD_POD=$(kubectl get pods -n openshift-machine-config-operator \
        --field-selector spec.nodeName="$NODE" \
        -l k8s-app=machine-config-daemon \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -z "$MCD_POD" ]; then
        _warn "Cannot check disk on $NODE (no MCD pod found)"
        continue
    fi

    DISK_PCT=$(kubectl exec -n openshift-machine-config-operator "$MCD_POD" \
        -c machine-config-daemon -- chroot /rootfs \
        df --output=pcent /var 2>/dev/null | tail -1 | tr -d ' %' || echo "0")

    if [ "$DISK_PCT" -ge "$DISK_THRESHOLD" ] 2>/dev/null; then
        _fail "$NODE /var at ${DISK_PCT}% (threshold: ${DISK_THRESHOLD}%) — risk of disk pressure evictions"
        DISK_ISSUES=true
    else
        _pass "$NODE /var at ${DISK_PCT}% (threshold: ${DISK_THRESHOLD}%)"
    fi
done

if [ "$DISK_ISSUES" = true ]; then
    echo "  Tip: ssh to the baremetal host and run 'podman system prune -af' on affected nodes"
fi
echo ""

# ── 10. LLM credentials ──────────────────────────────────────────────────────

echo "==> 10. LLM credentials..."
if kubectl get secret llm-credentials -n "${PLATFORM_NS}" &>/dev/null; then
    _pass "llm-credentials secret present"
else
    _fail "llm-credentials secret not found in ${PLATFORM_NS}"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "============================================="
echo " Preflight Summary"
echo "============================================="

if [ ${#WARNED[@]} -gt 0 ]; then
    echo ""
    echo "  Warnings (${#WARNED[@]}):"
    for w in "${WARNED[@]}"; do
        echo "    - $w"
    done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo "  FAILURES (${#FAILED[@]}):"
    for f in "${FAILED[@]}"; do
        echo "    - $f"
    done
    echo ""
    echo "  PREFLIGHT FAILED — fix the above before running validation."
    exit 1
fi

echo ""
echo "  All checks passed. Ready to launch parallel validation."
echo ""
exit 0
