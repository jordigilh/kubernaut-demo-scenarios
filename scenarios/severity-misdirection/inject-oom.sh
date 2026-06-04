#!/usr/bin/env bash
# Inject OOM condition on PostgreSQL by reducing its memory limit to 16Mi.
# PostgreSQL cannot initialize with this little memory and will be OOM-killed.
# The api-gateway then loses its database dependency and starts crash-looping.
#
# Alert timeline:
#   1. ContainerOOMKilling (warning) fires first -- postgres is OOM-killed
#   2. KubePodCrashLooping (critical) fires second -- api-gateway crash-loops
#
# The LLM must identify the warning-level OOM as the root cause, not the
# critical-level crash-loop.
set -euo pipefail

NAMESPACE="demo-services"

echo "==> Injecting OOM condition on postgres in ${NAMESPACE}..."

# Scale to zero first so the old healthy pod is fully terminated.
# Without this, RollingUpdate keeps the old pod alive (new pod never passes
# readiness because it OOMs), so api-gateway never loses its DB connection
# and KubePodCrashLooping never fires.
echo "    Scaling postgres to 0 to terminate healthy pod..."
kubectl scale deployment postgres -n "${NAMESPACE}" --replicas=0
kubectl rollout status deployment/postgres -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true
sleep 3

echo "    Patching postgres memory limit to 16Mi (will OOM on startup)..."
kubectl patch deployment postgres -n "${NAMESPACE}" --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"16Mi"},{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"16Mi"}]'

echo "    Scaling postgres back to 1 (new pod will OOM immediately)..."
kubectl scale deployment postgres -n "${NAMESPACE}" --replicas=1

echo "    Waiting for OOM to manifest..."
sleep 15
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "==> OOM condition injected."
echo "    postgres will be OOM-killed (warning alert fires first)."
echo "    api-gateway will crash-loop (critical alert fires second)."
echo "    The LLM must prioritize temporal causation over severity."
