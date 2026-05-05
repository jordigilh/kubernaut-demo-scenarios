#!/usr/bin/env bash
# Inject PostgreSQL failure in the shared infrastructure namespace.
# Apps in demo-xns-app lose their cross-namespace dependency and crash.
set -euo pipefail

INFRA_NS="demo-xns-infra"

echo "==> Injecting PostgreSQL failure in ${INFRA_NS}..."

echo "    Scaling postgres to 0 to ensure old pod is removed..."
kubectl scale deployment postgres -n "${INFRA_NS}" --replicas=0
kubectl rollout status deployment/postgres -n "${INFRA_NS}" --timeout=60s

echo "    Patching postgres Deployment with bad command (exit 1)..."
kubectl patch deployment postgres -n "${INFRA_NS}" --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/command","value":["sh","-c","echo INJECTED FAULT: postgres forced crash; exit 1"]}]'

echo "    Scaling postgres back to 1 (will crash-loop)..."
kubectl scale deployment postgres -n "${INFRA_NS}" --replicas=1

echo "    Waiting for postgres to start crash-looping..."
sleep 10
kubectl get pods -n "${INFRA_NS}"
echo ""
echo "==> PostgreSQL failure injected in ${INFRA_NS}."
echo "    Apps in demo-xns-app will lose cross-namespace connectivity within ~30s."
