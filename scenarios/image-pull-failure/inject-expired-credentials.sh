#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="demo-imagepull"

echo "==> Simulating expired registry credentials..."
kubectl delete secret registry-credentials -n "${NAMESPACE}"

echo "==> Killing running pod to force a re-pull..."
kubectl delete pod -n "${NAMESPACE}" -l app=inventory-api --grace-period=0 --force 2>/dev/null || true

echo "==> Fault injected. New pod will fail with ImagePullBackOff"
echo "   because the referenced ImagePullSecret no longer exists."
