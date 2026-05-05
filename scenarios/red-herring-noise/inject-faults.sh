#!/usr/bin/env bash
# Inject two simultaneous faults:
# 1. PRIMARY: Break PostgreSQL → causes api-gateway and worker to crash-loop
# 2. RED HERRING: canary-v2 already deployed with a nonexistent image tag
#
# The canary-v2 ImagePullBackOff is unrelated to the postgres cascade.
# The LLM must separate these independent incidents.
set -euo pipefail

NAMESPACE="demo-red-herring"

echo "==> Injecting PostgreSQL failure in ${NAMESPACE}..."

echo "    Scaling postgres to 0 to ensure old pod is removed..."
kubectl scale deployment postgres -n "${NAMESPACE}" --replicas=0
kubectl rollout status deployment/postgres -n "${NAMESPACE}" --timeout=60s

echo "    Patching postgres Deployment with bad command (exit 1)..."
kubectl patch deployment postgres -n "${NAMESPACE}" --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/command","value":["sh","-c","echo INJECTED FAULT: postgres forced crash; exit 1"]}]'

echo "    Scaling postgres back to 1 (will crash-loop)..."
kubectl scale deployment postgres -n "${NAMESPACE}" --replicas=1

echo "    Waiting for faults to propagate..."
sleep 10
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "==> Faults injected."
echo "    PRIMARY: postgres crash → api-gateway + worker crash-loop"
echo "    RED HERRING: canary-v2 stuck in ImagePullBackOff (unrelated)"
echo "    The LLM must separate these independent incidents."
