#!/usr/bin/env bash
# Exhaust ResourceQuota by scaling deployment beyond quota limits.
#
# The deployment starts at 1 replica × 256Mi (within the 512Mi quota).
# Scaling to 3 replicas requests 768Mi total, exceeding the quota.
# Because this is a pure scale-up (no template change), there is no
# new ReplicaSet and no previous revision to rollback to -- the LLM
# must recognise this as a capacity/policy constraint and escalate.
set -euo pipefail

NAMESPACE="demo-quota"

echo "==> Current ResourceQuota usage:"
kubectl describe quota namespace-quota -n "${NAMESPACE}"
echo ""

echo "==> Scaling api-server from 1 to 3 replicas (3 × 256Mi = 768Mi > 512Mi quota)..."
kubectl scale deployment api-server -n "${NAMESPACE}" --replicas=3

echo "==> Waiting for FailedCreate events..."
sleep 10

echo "==> Pod status (only 1-2 pods can fit within quota):"
kubectl get pods -n "${NAMESPACE}"
echo ""
echo "==> ReplicaSet status:"
kubectl get rs -n "${NAMESPACE}"
echo ""
echo "==> Events showing quota exhaustion:"
kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -10
echo ""
echo "==> Updated ResourceQuota usage:"
kubectl describe quota namespace-quota -n "${NAMESPACE}"
