#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="demo-route"

echo "==> Simulating blue/green misconfiguration..."
kubectl patch route storefront -n "${NAMESPACE}" --type=merge \
  -p '{"spec":{"to":{"name":"storefront-web-v2"}}}'

echo "==> Route patched to target non-existent service 'storefront-web-v2'."
echo "   External traffic will now receive 503 Service Unavailable."
