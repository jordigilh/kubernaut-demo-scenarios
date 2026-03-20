#!/usr/bin/env bash
# Shared GitOps helper functions for demo scenarios.
# Requires: platform-helper.sh sourced first (provides PLATFORM, get_argocd_namespace).

# Configure a Gitea webhook that notifies ArgoCD on push, enabling instant
# sync instead of waiting for the default ~3 min poll interval.
#
# Usage: setup_gitea_argocd_webhook <repo_owner> <repo_name>
#
# Handles:
#   - Gitea ROOT_URL alignment so ArgoCD matches repoURL
#   - SKIP_TLS_VERIFY + ALLOWED_HOST_LIST config
#   - ArgoCD webhook.gitea.secret generation
#   - Stale webhook cleanup + fresh webhook creation
#   - Platform-aware ArgoCD service URL (OCP vs Kind)
setup_gitea_argocd_webhook() {
    local repo_owner="$1" repo_name="$2"
    local argocd_ns gitea_pod argocd_svc_url webhook_secret existing_hooks
    local gitea_ns="${GITEA_NAMESPACE:-gitea}"
    local gitea_svc_url="http://gitea-http.${gitea_ns}:3000"
    local needs_restart=false

    argocd_ns=$(get_argocd_namespace)
    argocd_svc_url="https://openshift-gitops-server.${argocd_ns}.svc/api/webhook"
    if [ "$PLATFORM" != "ocp" ]; then
        argocd_svc_url="https://argocd-server.${argocd_ns}.svc/api/webhook"
    fi

    gitea_pod=$(kubectl get pods -n "${gitea_ns}" -l app.kubernetes.io/name=gitea \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$gitea_pod" ]; then
        echo "  WARNING: Gitea pod not found, skipping webhook setup."
        return 0
    fi

    # Gitea embeds ROOT_URL in webhook payloads. ArgoCD matches the URL
    # against Application.spec.source.repoURL. Both must agree or ArgoCD
    # silently ignores the push event. Set ROOT_URL to the in-cluster
    # service URL so the URLs match.
    local current_server_cfg
    current_server_cfg=$(kubectl get secret gitea-inline-config -n "${gitea_ns}" \
      -o jsonpath='{.data.server}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if ! echo "$current_server_cfg" | grep -q "ROOT_URL=${gitea_svc_url}"; then
        local gitea_domain="gitea-http.${gitea_ns}"
        kubectl patch secret gitea-inline-config -n "${gitea_ns}" --type=merge \
          -p "{\"stringData\":{\"server\":\"APP_DATA_PATH=/data\nDOMAIN=${gitea_domain}\nENABLE_PPROF=false\nHTTP_PORT=3000\nPROTOCOL=http\nROOT_URL=${gitea_svc_url}\nSSH_DOMAIN=${gitea_domain}\nSSH_LISTEN_PORT=2222\nSSH_PORT=22\nSTART_SSH_SERVER=true\"}}" 2>/dev/null
        echo "  Gitea ROOT_URL set to ${gitea_svc_url}."
        needs_restart=true
    fi

    # ArgoCD uses TLS internally; Gitea must skip certificate verification.
    local current_wh_cfg
    current_wh_cfg=$(kubectl get secret gitea-inline-config -n "${gitea_ns}" \
      -o jsonpath='{.data.webhook}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if ! echo "$current_wh_cfg" | grep -q "SKIP_TLS_VERIFY"; then
        kubectl patch secret gitea-inline-config -n "${gitea_ns}" --type=merge \
          -p '{"stringData":{"webhook":"SKIP_TLS_VERIFY=true\nALLOWED_HOST_LIST=*"}}' 2>/dev/null
        echo "  Gitea SKIP_TLS_VERIFY configured."
        needs_restart=true
    fi

    if [ "$needs_restart" = true ]; then
        kubectl rollout restart deployment/gitea -n "${gitea_ns}" 2>/dev/null
        kubectl rollout status deployment/gitea -n "${gitea_ns}" --timeout=120s 2>/dev/null
        gitea_pod=$(kubectl get pods -n "${gitea_ns}" -l app.kubernetes.io/name=gitea \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        echo "  Gitea restarted with updated configuration."
    fi

    # Ensure ArgoCD has a webhook.gitea.secret; generate one if missing.
    webhook_secret=$(kubectl get secret argocd-secret -n "${argocd_ns}" \
      -o jsonpath='{.data.webhook\.gitea\.secret}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ -z "$webhook_secret" ]; then
        webhook_secret=$(openssl rand -hex 20)
        kubectl patch secret argocd-secret -n "${argocd_ns}" --type=merge \
          -p "{\"stringData\":{\"webhook.gitea.secret\":\"${webhook_secret}\"}}"
        echo "  ArgoCD webhook.gitea.secret configured."
    else
        echo "  ArgoCD webhook.gitea.secret already present."
    fi

    # Create a Gitea API token via the CLI inside the pod.
    local gitea_token token_name
    token_name="kubernaut-wh-$$"
    gitea_token=$(kubectl exec -n "${gitea_ns}" "${gitea_pod}" -- \
      gitea admin user generate-access-token \
      -u "${repo_owner}" -t "${token_name}" \
      --scopes all --raw 2>/dev/null) || true
    if [ -z "$gitea_token" ]; then
        echo "  WARNING: Could not create Gitea token, skipping webhook setup."
        return 0
    fi

    # Delete any existing ArgoCD webhook, then recreate with the current
    # secret. This avoids stale secrets from prior runs causing silent
    # delivery failures.
    existing_hooks=$(kubectl exec -n "${gitea_ns}" "${gitea_pod}" -- \
      wget -q -O - \
      --header="Authorization: token ${gitea_token}" \
      "http://localhost:3000/api/v1/repos/${repo_owner}/${repo_name}/hooks" 2>/dev/null || echo "[]")

    local old_hook_ids
    old_hook_ids=$(echo "$existing_hooks" | jq -r '.[] | select(.config.url | contains("/api/webhook")) | .id' 2>/dev/null || true)

    for hid in $old_hook_ids; do
        kubectl exec -n "${gitea_ns}" "${gitea_pod}" -- \
          wget -q -O /dev/null \
          --header="Authorization: token ${gitea_token}" \
          --post-data="_method=DELETE" \
          "http://localhost:3000/api/v1/repos/${repo_owner}/${repo_name}/hooks/${hid}" 2>/dev/null || true
        echo "  Removed stale webhook (id=${hid})."
    done

    kubectl exec -n "${gitea_ns}" "${gitea_pod}" -- \
      wget -q -O /dev/null \
      --header="Authorization: token ${gitea_token}" \
      --header="Content-Type: application/json" \
      --post-data="{\"type\":\"gitea\",\"config\":{\"url\":\"${argocd_svc_url}\",\"content_type\":\"json\",\"secret\":\"${webhook_secret}\"},\"events\":[\"push\"],\"active\":true}" \
      "http://localhost:3000/api/v1/repos/${repo_owner}/${repo_name}/hooks" 2>/dev/null
    echo "  Gitea webhook created -> ${argocd_svc_url}"
}
