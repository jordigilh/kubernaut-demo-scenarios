#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="demo-scc"

echo "==> Simulating privileged requirement (SCC violation)..."
kubectl patch deployment metrics-agent -n "${NAMESPACE}" --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/securityContext","value":{
    "runAsUser": 0,
    "capabilities": {"add": ["NET_ADMIN"], "drop": ["ALL"]},
    "allowPrivilegeEscalation": true
  }}
]'

echo "==> Deployment patched to require root (UID 0) + NET_ADMIN."
echo "   New pods will fail SCC validation under restricted-v2."

echo "==> Scaling to 0 and back to force all pods through the new template..."
kubectl scale deployment metrics-agent -n "${NAMESPACE}" --replicas=0
sleep 3
kubectl scale deployment metrics-agent -n "${NAMESPACE}" --replicas=1
echo "   Scale-down/up complete; SCC will reject the new pod."
