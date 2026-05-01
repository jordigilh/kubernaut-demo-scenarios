#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="demo-rbac"

echo "==> Simulating accidental RoleBinding deletion (security audit cleanup)..."
kubectl delete rolebinding metrics-collector-binding -n "${NAMESPACE}"

echo "==> RoleBinding deleted. metrics-collector will lose API access."
echo "   Readiness probe will fail with 'forbidden', pod goes NotReady."
