#!/usr/bin/env bash
# Deploy Ansible Automation Platform (AAP) Controller on OCP via the official
# Red Hat operator, then configure it for Kubernaut Ansible-engine workflows.
#
# Mirrors awx-helper.sh but uses OLM + AutomationController CR instead of
# the community AWX operator.
#
# Prerequisites:
#   - OCP cluster with OperatorHub access (Red Hat Operators catalog)
#   - Kubernaut platform deployed in kubernaut-system
#   - Gitea deployed (for GitOps scenarios)
#
# Usage:
#   ./scripts/aap-helper.sh                     # Full AAP setup
#   ./scripts/aap-helper.sh --skip-operator      # Skip operator install
#   ./scripts/aap-helper.sh --configure-only     # Only configure AAP
#
# Issue #324: DiskPressure emptyDir migration scenario (Ansible engine)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AAP_NAMESPACE="${AAP_NAMESPACE:-aap}"
AAP_INSTANCE_NAME="kubernaut-controller"
AAP_ADMIN_USER="admin"
AAP_ADMIN_PASS="admin_demo_password"

AAP_PLAYBOOKS_REPO="https://github.com/jordigilh/kubernaut-test-playbooks.git"
KUBERNAUT_NS="${KUBERNAUT_NS:-kubernaut-system}"

SKIP_OPERATOR=false
CONFIGURE_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-operator)   SKIP_OPERATOR=true; shift ;;
        --configure-only)  CONFIGURE_ONLY=true; shift ;;
        --namespace)       AAP_NAMESPACE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--skip-operator] [--configure-only] [--namespace NS]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

TOTAL_START=$(date +%s)

echo "============================================="
echo " AAP Controller Setup for Ansible Engine"
echo " Namespace: ${AAP_NAMESPACE}"
echo "============================================="
echo ""

# ── 1. Install AAP Operator via OLM ──────────────────────────────────────────

install_aap_operator() {
    echo "==> Step 1: Installing AAP Operator via OLM..."

    kubectl create namespace "${AAP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    # Create OperatorGroup (required for single-namespace install)
    kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: aap-operator-group
  namespace: ${AAP_NAMESPACE}
spec:
  targetNamespaces:
    - ${AAP_NAMESPACE}
EOF

    # Create Subscription
    kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ansible-automation-platform-operator
  namespace: ${AAP_NAMESPACE}
spec:
  channel: stable-2.5
  installPlanApproval: Automatic
  name: ansible-automation-platform-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    echo "  Waiting for AAP Operator CSV to install..."
    local deadline=$(($(date +%s) + 300))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local csv_phase
        csv_phase=$(kubectl get csv -n "${AAP_NAMESPACE}" -l operators.coreos.com/ansible-automation-platform-operator.${AAP_NAMESPACE}= \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        if [ "$csv_phase" = "Succeeded" ]; then
            echo "  AAP Operator installed successfully."
            echo ""
            return 0
        fi
        echo "  CSV phase: ${csv_phase:-Pending}..."
        sleep 15
    done

    echo "ERROR: AAP Operator did not install within 5 minutes."
    kubectl get csv -n "${AAP_NAMESPACE}"
    return 1
}

# ── 2. Deploy AutomationController ───────────────────────────────────────────

deploy_controller() {
    echo "==> Step 2: Deploying AutomationController (${AAP_INSTANCE_NAME})..."

    # Admin password secret
    kubectl create secret generic "${AAP_INSTANCE_NAME}-admin-password" \
        -n "${AAP_NAMESPACE}" \
        --from-literal=password="${AAP_ADMIN_PASS}" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl apply -f - <<EOF
apiVersion: automationcontroller.ansible.com/v1beta1
kind: AutomationController
metadata:
  name: ${AAP_INSTANCE_NAME}
  namespace: ${AAP_NAMESPACE}
spec:
  admin_user: ${AAP_ADMIN_USER}
  admin_password_secret: ${AAP_INSTANCE_NAME}-admin-password
  replicas: 1
  web_resource_requirements:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: "2"
      memory: 2Gi
  task_resource_requirements:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: "2"
      memory: 2Gi
  ee_resource_requirements:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: "1"
      memory: 1Gi
EOF

    echo "  AutomationController CR applied."
    echo ""
}

# ── 3. Wait for AAP Controller to be ready ───────────────────────────────────

wait_for_controller() {
    echo "==> Step 3: Waiting for AAP Controller to be ready (up to 15 min)..."

    local deadline=$(($(date +%s) + 900))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local status
        status=$(kubectl get automationcontroller "${AAP_INSTANCE_NAME}" -n "${AAP_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Running")].status}' 2>/dev/null || echo "")
        if [ "$status" = "True" ]; then
            echo "  AAP Controller is running."

            # Verify web pod is ready
            local ready_pods
            ready_pods=$(kubectl get pods -n "${AAP_NAMESPACE}" \
                -l "app.kubernetes.io/managed-by=automationcontroller-operator" \
                --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
            if [ "$ready_pods" -gt 0 ]; then
                echo "  AAP Controller pods ready (${ready_pods} running)."
                echo ""
                return 0
            fi
        fi

        local pod_status
        pod_status=$(kubectl get pods -n "${AAP_NAMESPACE}" \
            -l "app.kubernetes.io/managed-by=automationcontroller-operator" \
            --no-headers 2>/dev/null | head -3 || echo "(no pods yet)")
        echo "  Waiting... Controller status: ${status:-Pending}"
        echo "  ${pod_status}"
        sleep 20
    done

    echo "ERROR: AAP Controller did not become ready within 15 minutes."
    kubectl get pods -n "${AAP_NAMESPACE}"
    return 1
}

# ── 4. Get AAP API URL ───────────────────────────────────────────────────────

get_aap_url() {
    # Try OCP Route first
    local route_host
    route_host=$(kubectl get route "${AAP_INSTANCE_NAME}" -n "${AAP_NAMESPACE}" \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

    if [ -n "$route_host" ]; then
        local tls
        tls=$(kubectl get route "${AAP_INSTANCE_NAME}" -n "${AAP_NAMESPACE}" \
            -o jsonpath='{.spec.tls}' 2>/dev/null || echo "")
        if [ -n "$tls" ]; then
            AAP_URL="https://${route_host}"
        else
            AAP_URL="http://${route_host}"
        fi
        AAP_INTERNAL_URL="http://${AAP_INSTANCE_NAME}-service.${AAP_NAMESPACE}:80"
        echo "  AAP Route: ${AAP_URL}"
        echo "  AAP Internal: ${AAP_INTERNAL_URL}"
        return 0
    fi

    # Fallback to service
    AAP_URL="http://${AAP_INSTANCE_NAME}-service.${AAP_NAMESPACE}:80"
    AAP_INTERNAL_URL="${AAP_URL}"
    echo "  AAP Service: ${AAP_URL}"
}

# ── 5. Configure AAP (org, project, inventory, templates, token) ─────────────

aap_api() {
    local method="$1" url="$2" token="${3:-}"
    shift 2; [ $# -gt 0 ] && shift

    local auth_args=()
    if [ -n "$token" ]; then
        auth_args=(-H "Authorization: Bearer ${token}")
    else
        auth_args=(-u "${AAP_ADMIN_USER}:${AAP_ADMIN_PASS}")
    fi

    local data_args=()
    if [ -n "${AAP_API_BODY:-}" ]; then
        data_args=(-d "${AAP_API_BODY}")
    fi

    curl -skf -X "${method}" "${url}" \
        -H "Content-Type: application/json" \
        "${auth_args[@]}" \
        "${data_args[@]}" 2>/dev/null || true
}

configure_aap() {
    echo "==> Step 4: Configuring AAP Controller..."

    get_aap_url

    # Start port-forward to internal service for API calls
    kubectl port-forward -n "${AAP_NAMESPACE}" svc/"${AAP_INSTANCE_NAME}-service" 8052:80 &
    PF_PID=$!
    sleep 3
    local api_base="http://localhost:8052"

    # 4a. Organization
    echo "  Creating organization..."
    AAP_API_BODY='{"name":"Kubernaut Demo","description":"Demo organization for Kubernaut scenarios"}'
    local org_result
    org_result=$(aap_api POST "${api_base}/api/v2/organizations/" "")
    local org_id
    org_id=$(echo "$org_result" | jq -r '.id // empty' 2>/dev/null || echo "")
    if [ -z "$org_id" ]; then
        org_id=$(AAP_API_BODY="" aap_api GET "${api_base}/api/v2/organizations/?name=Kubernaut+Demo" "" | \
            jq -r '.results[0].id // 1' 2>/dev/null || echo "1")
    fi
    echo "    Organization ID: ${org_id}"

    # 4b. Project (Git SCM -> kubernaut-test-playbooks)
    echo "  Creating project..."
    AAP_API_BODY=$(jq -n \
        --arg name "kubernaut-demo-playbooks" \
        --arg desc "Ansible playbooks for Kubernaut demo scenarios" \
        --argjson org "$org_id" \
        --arg repo "${AAP_PLAYBOOKS_REPO}" \
        '{name:$name, description:$desc, organization:$org, scm_type:"git", scm_url:$repo, scm_branch:"main", scm_update_on_launch:true}')
    local proj_result
    proj_result=$(aap_api POST "${api_base}/api/v2/projects/" "")
    local proj_id
    proj_id=$(echo "$proj_result" | jq -r '.id // empty' 2>/dev/null || echo "")
    if [ -z "$proj_id" ]; then
        proj_id=$(AAP_API_BODY="" aap_api GET "${api_base}/api/v2/projects/?name=kubernaut-demo-playbooks" "" | \
            jq -r '.results[0].id // empty' 2>/dev/null || echo "")
    fi
    echo "    Project ID: ${proj_id}"

    echo "  Waiting for project sync..."
    local sync_deadline=$(($(date +%s) + 300))
    while [ "$(date +%s)" -lt "$sync_deadline" ]; do
        local proj_status
        proj_status=$(AAP_API_BODY="" aap_api GET "${api_base}/api/v2/projects/${proj_id}/" "" | \
            jq -r '.status // empty' 2>/dev/null || echo "")
        if [ "$proj_status" = "successful" ]; then
            echo "    Project synced."
            break
        elif [ "$proj_status" = "failed" ] || [ "$proj_status" = "error" ]; then
            echo "ERROR: Project sync failed (status: ${proj_status})"
            kill "${PF_PID}" 2>/dev/null || true
            return 1
        fi
        sleep 5
    done

    # 4c. Inventory
    echo "  Creating inventory..."
    AAP_API_BODY=$(jq -n --argjson org "$org_id" \
        '{name:"localhost", description:"In-cluster execution", organization:$org}')
    local inv_result
    inv_result=$(aap_api POST "${api_base}/api/v2/inventories/" "")
    local inv_id
    inv_id=$(echo "$inv_result" | jq -r '.id // empty' 2>/dev/null || echo "")
    if [ -z "$inv_id" ]; then
        inv_id=$(AAP_API_BODY="" aap_api GET "${api_base}/api/v2/inventories/?name=localhost" "" | \
            jq -r '.results[0].id // empty' 2>/dev/null || echo "")
    fi
    echo "    Inventory ID: ${inv_id}"

    AAP_API_BODY='{"name":"localhost","variables":"ansible_connection: local\nansible_python_interpreter: /usr/bin/python3"}'
    aap_api POST "${api_base}/api/v2/inventories/${inv_id}/hosts/" "" >/dev/null

    # 4d. Job templates
    create_job_template() {
        local name="$1" desc="$2" playbook="$3"
        echo "  Creating job template (${name})..."
        AAP_API_BODY=$(jq -n --argjson proj "$proj_id" --argjson inv "$inv_id" \
            --arg name "$name" --arg desc "$desc" --arg pb "$playbook" \
            '{name:$name, description:$desc, project:$proj, playbook:$pb, inventory:$inv, ask_variables_on_launch:true}')
        local tmpl_result
        tmpl_result=$(aap_api POST "${api_base}/api/v2/job_templates/" "")
        local tmpl_id
        tmpl_id=$(echo "$tmpl_result" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [ -z "$tmpl_id" ]; then
            tmpl_id=$(AAP_API_BODY="" aap_api GET "${api_base}/api/v2/job_templates/?name=${name// /+}" "" | \
                jq -r '.results[0].id // empty' 2>/dev/null || echo "")
        fi
        echo "    Job Template ID: ${tmpl_id}"
        echo "$tmpl_id"
    }

    local memory_tmpl_id
    memory_tmpl_id=$(create_job_template \
        "kubernaut-gitops-update-memory" \
        "GitOps: update memory limits via git commit" \
        "playbooks/gitops-update-memory-limits.yml")

    local migrate_tmpl_id
    migrate_tmpl_id=$(create_job_template \
        "kubernaut-migrate-emptydir-to-pvc" \
        "DiskPressure: migrate emptyDir database to PVC via GitOps" \
        "playbooks/gitops-migrate-emptydir-to-pvc.yml")

    # 4e. K8s ServiceAccount credential for EE
    echo "  Creating K8s ServiceAccount for AAP EE..."
    kubectl apply -f - <<EOFK8S
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aap-ee-kubernaut
  namespace: ${AAP_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: aap-ee-kubernaut
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "patch"]
  - apiGroups: [""]
    resources: ["pods", "services", "secrets", "persistentvolumeclaims", "configmaps"]
    verbs: ["get", "list", "create", "delete", "patch"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "patch"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "create", "delete", "watch"]
  - apiGroups: ["argoproj.io"]
    resources: ["applications"]
    verbs: ["get", "list"]
  - apiGroups: ["kubernaut.ai"]
    resources: ["workflowexecutions"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aap-ee-kubernaut
subjects:
  - kind: ServiceAccount
    name: aap-ee-kubernaut
    namespace: ${AAP_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: aap-ee-kubernaut
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Secret
metadata:
  name: aap-ee-kubernaut-token
  namespace: ${AAP_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: aap-ee-kubernaut
type: kubernetes.io/service-account-token
EOFK8S

    echo "  Waiting for SA token..."
    local sa_deadline=$(($(date +%s) + 30))
    local sa_token=""
    while [ "$(date +%s)" -lt "$sa_deadline" ]; do
        sa_token=$(kubectl get secret aap-ee-kubernaut-token -n "${AAP_NAMESPACE}" \
            -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if [ -n "$sa_token" ]; then break; fi
        sleep 2
    done

    local k8s_host="https://kubernetes.default.svc"

    echo "  Registering K8s credential in AAP..."
    AAP_API_BODY=$(jq -n \
        --argjson org "$org_id" \
        --arg token "$sa_token" \
        --arg host "$k8s_host" \
        '{name:"kubernaut-k8s-credential", description:"In-cluster K8s access for AAP EE (Kubernaut scenarios)", organization:$org, credential_type:17, inputs:{host:$host, bearer_token:$token, verify_ssl:false}}')
    local k8s_cred_result
    k8s_cred_result=$(aap_api POST "${api_base}/api/v2/credentials/" "")
    local k8s_cred_id
    k8s_cred_id=$(echo "$k8s_cred_result" | jq -r '.id // empty' 2>/dev/null || echo "")
    if [ -z "$k8s_cred_id" ]; then
        k8s_cred_id=$(AAP_API_BODY="" aap_api GET "${api_base}/api/v2/credentials/?name=kubernaut-k8s-credential" "" | \
            jq -r '.results[0].id // empty' 2>/dev/null || echo "")
    fi
    echo "    K8s credential ID: ${k8s_cred_id}"

    # Attach K8s credential to all job templates
    for tmpl_id_val in "$memory_tmpl_id" "$migrate_tmpl_id"; do
        local clean_id
        clean_id=$(echo "$tmpl_id_val" | tail -1)  # last line is the ID
        if [ -n "$clean_id" ] && [ -n "$k8s_cred_id" ]; then
            AWX_API_BODY="" AAP_API_BODY=$(jq -n --argjson id "$k8s_cred_id" '{id:$id}')
            aap_api POST "${api_base}/api/v2/job_templates/${clean_id}/credentials/" "" >/dev/null
            echo "    K8s credential attached to template ${clean_id}."
        fi
    done

    # 4f. API token for WE controller
    echo "  Creating API token for WE controller..."
    AAP_API_BODY='{"description":"Kubernaut WE controller token","scope":"write"}'
    local token_result
    token_result=$(aap_api POST "${api_base}/api/v2/users/1/personal_tokens/" "")
    local api_token
    api_token=$(echo "$token_result" | jq -r '.token // empty' 2>/dev/null || echo "")

    if [ -z "$api_token" ]; then
        echo "ERROR: Failed to create API token"
        kill "${PF_PID}" 2>/dev/null || true
        return 1
    fi
    echo "    API token created."

    # Store token in Kubernaut namespace
    kubectl create secret generic aap-api-token \
        -n "${KUBERNAUT_NS}" \
        --from-literal=token="${api_token}" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "    Token Secret created (aap-api-token in ${KUBERNAUT_NS})."

    kill "${PF_PID}" 2>/dev/null || true
    echo ""
    echo "  AAP configuration complete."
    echo ""
}

# ── 6. Patch WE controller with Ansible config ──────────────────────────────

patch_we_controller() {
    echo "==> Step 5: Patching WE controller with Ansible config..."

    local current_config
    current_config=$(kubectl get configmap workflowexecution-config \
        -n "${KUBERNAUT_NS}" -o jsonpath='{.data.workflowexecution\.yaml}' 2>/dev/null || echo "")

    if echo "$current_config" | grep -q "ansible:" 2>/dev/null; then
        echo "  Ansible config already present in WE controller ConfigMap. Updating..."
    fi

    local ansible_section
    ansible_section=$(cat <<EOF

ansible:
  apiURL: "${AAP_INTERNAL_URL:-http://${AAP_INSTANCE_NAME}-service.${AAP_NAMESPACE}:80}"
  tokenSecretRef:
    name: "aap-api-token"
    namespace: "${KUBERNAUT_NS}"
    key: "token"
  insecure: true
  organizationID: 1
EOF
)

    # Remove existing ansible section if present, then append new one
    local base_config
    base_config=$(echo "$current_config" | sed '/^ansible:/,$d')
    local new_config="${base_config}${ansible_section}"

    kubectl patch configmap workflowexecution-config -n "${KUBERNAUT_NS}" \
        --type merge -p "{\"data\":{\"workflowexecution.yaml\":$(echo "$new_config" | jq -Rs .)}}"
    echo "  ConfigMap updated with AAP ansible config."

    echo "  Restarting WE controller..."
    kubectl rollout restart deployment/workflowexecution-controller -n "${KUBERNAUT_NS}"
    kubectl rollout status deployment/workflowexecution-controller \
        -n "${KUBERNAUT_NS}" --timeout=120s
    echo "  WE controller restarted with Ansible executor enabled."
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

if [ "$CONFIGURE_ONLY" = true ]; then
    configure_aap
    patch_we_controller
else
    if [ "$SKIP_OPERATOR" = false ]; then
        install_aap_operator
    fi
    deploy_controller
    wait_for_controller
    configure_aap
    patch_we_controller
fi

TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - TOTAL_START))
total_mins=$((TOTAL_DURATION / 60))
total_secs=$((TOTAL_DURATION % 60))

echo "============================================="
echo " AAP Controller setup complete (${total_mins}m ${total_secs}s)"
echo "============================================="
echo ""
echo "  AAP URL: ${AAP_URL:-http://${AAP_INSTANCE_NAME}-service.${AAP_NAMESPACE}:80}"
echo "  Job Templates:"
echo "    - kubernaut-gitops-update-memory"
echo "    - kubernaut-migrate-emptydir-to-pvc"
echo "  WE controller: ansible executor enabled"
echo ""
echo "  Next: run a scenario with engine=ansible"
echo "    ./scenarios/disk-pressure-emptydir/run.sh"
echo "    ./scenarios/memory-limits-gitops-ansible/run.sh"
