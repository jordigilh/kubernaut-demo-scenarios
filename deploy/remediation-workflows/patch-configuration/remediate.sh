#!/bin/sh
set -e

# patch-configuration-v1 remediate.sh
# Restores a ConfigMap to its known-good state by removing bad keys or
# reverting values, then restarts the Deployment that mounts it.

echo "=== Phase 1: Validate ==="
echo "Target: ${TARGET_RESOURCE_KIND}/${TARGET_RESOURCE_NAME} in ${TARGET_RESOURCE_NAMESPACE}"

if [ "$TARGET_RESOURCE_KIND" = "ConfigMap" ]; then
    CM_NAME="$TARGET_RESOURCE_NAME"
    # Find the Deployment that mounts this ConfigMap
    DEPLOY_NAME=$(kubectl get deployments -n "$TARGET_RESOURCE_NAMESPACE" -o json 2>/dev/null \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
cm = '$CM_NAME'
for d in data.get('items', []):
    for v in d['spec']['template']['spec'].get('volumes', []):
        ref = v.get('configMap', {}).get('name', '')
        if ref == cm:
            print(d['metadata']['name'])
            sys.exit(0)
    for c in d['spec']['template']['spec'].get('containers', []):
        for ef in c.get('envFrom', []):
            if ef.get('configMapRef', {}).get('name', '') == cm:
                print(d['metadata']['name'])
                sys.exit(0)
" 2>/dev/null || true)
elif [ "$TARGET_RESOURCE_KIND" = "Deployment" ]; then
    DEPLOY_NAME="$TARGET_RESOURCE_NAME"
    # Find ConfigMaps mounted by this Deployment
    CM_NAME=$(kubectl get "deployment/$DEPLOY_NAME" -n "$TARGET_RESOURCE_NAMESPACE" -o json 2>/dev/null \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
for v in data['spec']['template']['spec'].get('volumes', []):
    cm = v.get('configMap', {}).get('name', '')
    if cm:
        print(cm)
        sys.exit(0)
for c in data['spec']['template']['spec'].get('containers', []):
    for ef in c.get('envFrom', []):
        ref = ef.get('configMapRef', {}).get('name', '')
        if ref:
            print(ref)
            sys.exit(0)
" 2>/dev/null || true)
else
    echo "ERROR: Unsupported target kind: $TARGET_RESOURCE_KIND"
    exit 1
fi

if [ -z "$CM_NAME" ]; then
    echo "ERROR: Could not identify target ConfigMap"
    exit 1
fi

echo "ConfigMap: $CM_NAME"
echo "Deployment: ${DEPLOY_NAME:-unknown}"

# Fetch current ConfigMap data
CM_DATA=$(kubectl get configmap "$CM_NAME" -n "$TARGET_RESOURCE_NAMESPACE" -o json 2>/dev/null)
if [ -z "$CM_DATA" ]; then
    echo "ERROR: ConfigMap $CM_NAME not found"
    exit 1
fi
echo "ConfigMap exists with $(echo "$CM_DATA" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('data',{})))" 2>/dev/null || echo '?') data keys"

echo "=== Phase 2: Action ==="

# Strategy: look for a known-good backup ConfigMap (<name>-backup or <name>-good)
BACKUP_CM=""
for suffix in "-backup" "-good" "-original" "-default"; do
    if kubectl get configmap "${CM_NAME}${suffix}" -n "$TARGET_RESOURCE_NAMESPACE" >/dev/null 2>&1; then
        BACKUP_CM="${CM_NAME}${suffix}"
        break
    fi
done

if [ -n "$BACKUP_CM" ]; then
    echo "Found backup ConfigMap: $BACKUP_CM"
    GOOD_DATA=$(kubectl get configmap "$BACKUP_CM" -n "$TARGET_RESOURCE_NAMESPACE" \
        -o jsonpath='{.data}' 2>/dev/null)
    kubectl patch configmap "$CM_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
        --type=merge -p "{\"data\": $GOOD_DATA}"
    echo "Restored ConfigMap from backup: $BACKUP_CM"
else
    echo "No backup ConfigMap found. Attempting to remove known-bad keys..."
    # Remove keys that look injected/invalid (common patterns)
    BAD_KEYS=$(echo "$CM_DATA" | python3 -c "
import json, sys
data = json.load(sys.stdin).get('data', {})
bad = [k for k in data if 'invalid' in k.lower() or 'bad' in k.lower()
       or 'broken' in k.lower() or 'inject' in k.lower()]
# Also check values for obviously invalid content
for k, v in data.items():
    if 'invalid_directive' in str(v) or 'INVALID' in str(v):
        if k not in bad:
            bad.append(k)
print(' '.join(bad))
" 2>/dev/null || true)

    if [ -n "$BAD_KEYS" ]; then
        echo "Removing bad keys: $BAD_KEYS"
        PATCH='{"data":{'
        first=true
        for key in $BAD_KEYS; do
            if [ "$first" = "true" ]; then first=false; else PATCH="${PATCH},"; fi
            PATCH="${PATCH}\"${key}\":null"
        done
        PATCH="${PATCH}}}"
        kubectl patch configmap "$CM_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
            --type=merge -p "$PATCH"
        echo "Removed bad keys from ConfigMap"
    else
        echo "WARN: Could not identify bad keys automatically. Escalating."
        exit 1
    fi
fi

# Restart the Deployment to pick up the ConfigMap change
if [ -n "$DEPLOY_NAME" ]; then
    echo "Restarting deployment/$DEPLOY_NAME to pick up ConfigMap changes..."
    kubectl rollout restart "deployment/$DEPLOY_NAME" -n "$TARGET_RESOURCE_NAMESPACE"
    echo "Waiting for rollout to complete..."
    kubectl rollout status "deployment/$DEPLOY_NAME" \
        -n "$TARGET_RESOURCE_NAMESPACE" --timeout=120s
fi

echo "=== Phase 3: Verify ==="

if [ -n "$DEPLOY_NAME" ]; then
    READY=$(kubectl get "deployment/$DEPLOY_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    DESIRED=$(kubectl get "deployment/$DEPLOY_NAME" -n "$TARGET_RESOURCE_NAMESPACE" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    echo "Replicas: $READY/$DESIRED ready"
    if [ "$READY" = "$DESIRED" ] && [ "$READY" != "0" ]; then
        echo "=== SUCCESS: ConfigMap patched and Deployment restarted, all replicas ready ==="
    else
        echo "WARNING: Not all replicas ready after restart ($READY/$DESIRED)"
        exit 1
    fi
else
    echo "=== SUCCESS: ConfigMap patched (no associated Deployment found to restart) ==="
fi
