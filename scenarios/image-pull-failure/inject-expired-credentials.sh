#!/usr/bin/env bash
# Inject single fault: delete the ImagePullSecret so the kubelet can no
# longer authenticate to the OCP internal registry for cross-namespace pulls.
set -euo pipefail

NAMESPACE="demo-inventory"

echo "==> Simulating expired registry credentials (deleting ImagePullSecret)..."
kubectl delete secret registry-credentials -n "${NAMESPACE}"

echo "==> Scaling to 0 then back to force new pods..."
kubectl scale deployment inventory-api -n "${NAMESPACE}" --replicas=0
sleep 3
kubectl scale deployment inventory-api -n "${NAMESPACE}" --replicas=1

echo "==> Fault injected. New pod will fail with ImagePullBackOff"
echo "   because the cross-namespace pull secret no longer exists."
