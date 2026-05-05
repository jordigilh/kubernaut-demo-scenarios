#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="demo-imagepull"

echo "==> Simulating expired registry credentials..."
kubectl delete secret registry-credentials -n "${NAMESPACE}"

echo "==> Patching deployment to use a non-existent private image..."
kubectl patch deployment inventory-api -n "${NAMESPACE}" --type=merge \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"inventory-api","image":"registry.k8s.io/e2e-test-images/busybox:does-not-exist-v999"}]}}}}'

echo "==> Scaling to 0 then back to force new pods..."
kubectl scale deployment inventory-api -n "${NAMESPACE}" --replicas=0
sleep 3
kubectl scale deployment inventory-api -n "${NAMESPACE}" --replicas=1

echo "==> Fault injected. New pod will fail with ImagePullBackOff"
echo "   because the image tag does not exist."
