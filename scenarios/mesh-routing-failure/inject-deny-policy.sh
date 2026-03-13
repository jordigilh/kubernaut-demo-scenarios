#!/usr/bin/env bash
# Inject restrictive Istio AuthorizationPolicy to block all traffic
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Injecting deny-all AuthorizationPolicy..."
kubectl apply -f "${SCRIPT_DIR}/manifests/deny-policy.yaml"

echo "==> AuthorizationPolicy applied. Istio sidecar will deny all inbound traffic."
echo "    Requests to api-server will return HTTP 403 Forbidden."
echo "==> Watch: kubectl get pods -n demo-mesh-failure -w"
echo "==> Check: kubectl exec -n demo-mesh-failure deploy/traffic-gen -- curl -s -o /dev/null -w '%{http_code}' http://api-server:8080/"
