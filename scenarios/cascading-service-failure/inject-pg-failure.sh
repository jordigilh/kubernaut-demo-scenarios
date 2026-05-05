#!/usr/bin/env bash
# Inject PostgreSQL failure by patching the postgres Deployment with a bad command.
# Both order-processor and inventory-sync lose their database dependency and crash.
set -euo pipefail

NAMESPACE="demo-cascade"

echo "==> Injecting PostgreSQL failure in ${NAMESPACE}..."

echo "    Scaling postgres to 0 to ensure old pod is removed..."
kubectl scale deployment postgres -n "${NAMESPACE}" --replicas=0
kubectl rollout status deployment/postgres -n "${NAMESPACE}" --timeout=60s

echo "    Patching postgres Deployment with bad command (exit 1)..."
kubectl patch deployment postgres -n "${NAMESPACE}" --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/command","value":["sh","-c","echo INJECTED FAULT: postgres forced crash; exit 1"]}]'

echo "    Scaling postgres back to 1 (will crash-loop)..."
kubectl scale deployment postgres -n "${NAMESPACE}" --replicas=1

echo "    Waiting for postgres to start crash-looping..."
sleep 10
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "==> PostgreSQL failure injected. Dependent apps will crash within ~30s."
