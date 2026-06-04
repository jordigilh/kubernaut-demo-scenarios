#!/bin/sh
set -e

# fix-image-reference-v1 remediate.sh
# Corrects a Deployment's container image reference when it points to a
# non-existent tag or wrong registry, then waits for rollout.

echo "=== Phase 1: Validate ==="
echo "Target: ${TARGET_RESOURCE_KIND}/${TARGET_RESOURCE_NAME} in ${TARGET_RESOURCE_NAMESPACE}"

# Resolve ReplicaSet -> Deployment if needed (kubernaut#693)
if ! kubectl get "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" >/dev/null 2>&1; then
    OWNER=$(kubectl get replicaset "$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
        -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}' 2>/dev/null || true)
    if [ -n "$OWNER" ]; then
        echo "WARN: '$TARGET_RESOURCE_NAME' is a ReplicaSet, resolved to Deployment '$OWNER'"
        TARGET_RESOURCE_NAME="$OWNER"
    fi
fi

# Get current image references
DEPLOY_JSON=$(kubectl get "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" -o json 2>/dev/null)
if [ -z "$DEPLOY_JSON" ]; then
    echo "ERROR: Deployment $TARGET_RESOURCE_NAME not found"
    exit 1
fi

CURRENT_IMAGES=$(echo "$DEPLOY_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for c in d['spec']['template']['spec']['containers']:
    print(f\"  {c['name']}: {c['image']}\")
" 2>/dev/null)
echo "Current container images:"
echo "$CURRENT_IMAGES"

# Check for pods in ImagePullBackOff
BAD_PODS=$(kubectl get pods -n "$TARGET_RESOURCE_NAMESPACE" \
    -l "app=$TARGET_RESOURCE_NAME" --no-headers 2>/dev/null \
    | grep -c "ImagePullBackOff\|ErrImagePull" || echo "0")
echo "Pods in ImagePullBackOff: $BAD_PODS"

if [ "$BAD_PODS" -eq 0 ]; then
    echo "WARN: No pods currently in ImagePullBackOff. Checking events..."
fi

echo "=== Phase 2: Action ==="

# Strategy: find the known-good image from the previous ReplicaSet
GOOD_IMAGE=$(echo "$DEPLOY_JSON" | python3 -c "
import json, sys, subprocess, re

d = json.load(sys.stdin)
ns = d['metadata']['namespace']
name = d['metadata']['name']
current_rs = d['spec']['template']['metadata'].get('labels', {}).get('pod-template-hash', '')

# List all ReplicaSets owned by this Deployment
result = subprocess.run(
    ['kubectl', 'get', 'replicasets', '-n', ns,
     '-l', f'app={name}', '-o', 'json'],
    capture_output=True, text=True)
rs_data = json.loads(result.stdout)

# Find the previous healthy RS (replicas > 0 or most recent before current)
candidates = []
for rs in rs_data.get('items', []):
    rs_hash = rs['metadata']['labels'].get('pod-template-hash', '')
    if rs_hash == current_rs:
        continue
    ready = rs.get('status', {}).get('readyReplicas', 0) or 0
    replicas = rs.get('status', {}).get('replicas', 0) or 0
    rev = int(rs['metadata'].get('annotations', {}).get(
        'deployment.kubernetes.io/revision', '0'))
    image = rs['spec']['template']['spec']['containers'][0]['image']
    candidates.append((rev, ready, image))

candidates.sort(key=lambda x: (-x[0], -x[1]))
for rev, ready, image in candidates:
    if ready > 0 or rev > 0:
        print(image)
        sys.exit(0)

# Fallback: strip the tag and use 'latest' or a known pattern
sys.exit(1)
" 2>/dev/null)

if [ -n "$GOOD_IMAGE" ]; then
    echo "Found known-good image from previous revision: $GOOD_IMAGE"
    CONTAINER_NAME=$(echo "$DEPLOY_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['spec']['template']['spec']['containers'][0]['name'])
" 2>/dev/null)
    echo "Patching container '$CONTAINER_NAME' image to: $GOOD_IMAGE"
    kubectl set image "deployment/$TARGET_RESOURCE_NAME" \
        -n "$TARGET_RESOURCE_NAMESPACE" \
        "${CONTAINER_NAME}=${GOOD_IMAGE}"
else
    echo "ERROR: Could not determine known-good image from rollout history"
    exit 1
fi

echo "Waiting for rollout to complete..."
kubectl rollout status "deployment/$TARGET_RESOURCE_NAME" \
    -n "$TARGET_RESOURCE_NAMESPACE" --timeout=120s

echo "=== Phase 3: Verify ==="

READY=$(kubectl get "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
DESIRED=$(kubectl get "deployment/$TARGET_RESOURCE_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
echo "Replicas: $READY/$DESIRED ready"

STILL_BAD=$(kubectl get pods -n "$TARGET_RESOURCE_NAMESPACE" \
    -l "app=$TARGET_RESOURCE_NAME" --no-headers 2>/dev/null \
    | grep -c "ImagePullBackOff\|ErrImagePull" || echo "0")

if [ "$READY" = "$DESIRED" ] && [ "$READY" != "0" ] && [ "$STILL_BAD" -eq 0 ]; then
    echo "=== SUCCESS: Image reference corrected, all replicas ready, no ImagePullBackOff ==="
else
    echo "WARNING: Not fully recovered ($READY/$DESIRED ready, $STILL_BAD still pulling)"
    exit 1
fi
