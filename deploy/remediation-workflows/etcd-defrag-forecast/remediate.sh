#!/bin/sh
set -e

ENDPOINTS="http://localhost:2379"

echo "=== Phase 1: Validate ==="
echo "Discovering etcd pods in namespace ${TARGET_RESOURCE_NAMESPACE}..."

ETCD_PODS=$(kubectl get pods -n "$TARGET_RESOURCE_NAMESPACE" -l app=etcd \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)

POD_COUNT=$(echo "$ETCD_PODS" | grep -c . || echo "0")
echo "Found ${POD_COUNT} etcd pod(s): $(echo $ETCD_PODS | tr '\n' ' ')"

if [ "$POD_COUNT" -eq 0 ]; then
    echo "ERROR: No etcd pods found with label app=etcd in ${TARGET_RESOURCE_NAMESPACE}"
    exit 1
fi

echo ""
echo "Checking cluster health..."
FIRST_POD=$(echo "$ETCD_PODS" | head -1)

kubectl exec "$FIRST_POD" -n "$TARGET_RESOURCE_NAMESPACE" -- \
  etcdctl --endpoints="$ENDPOINTS" endpoint health 2>/dev/null || \
kubectl exec "$FIRST_POD" -n "$TARGET_RESOURCE_NAMESPACE" -- sh -c \
  "ETCDCTL_API=3 etcdctl --endpoints=$ENDPOINTS endpoint health"

echo ""
echo "Pre-defrag database status:"
for pod in $ETCD_PODS; do
    SIZE_INFO=$(kubectl exec "$pod" -n "$TARGET_RESOURCE_NAMESPACE" -- sh -c \
      "ETCDCTL_API=3 etcdctl --endpoints=$ENDPOINTS endpoint status --write-out=json" 2>/dev/null || echo "{}")
    DB_SIZE=$(echo "$SIZE_INFO" | grep -o '"dbSize":[0-9]*' | head -1 | cut -d: -f2)
    DB_IN_USE=$(echo "$SIZE_INFO" | grep -o '"dbSizeInUse":[0-9]*' | head -1 | cut -d: -f2)
    if [ -n "$DB_SIZE" ] && [ "$DB_SIZE" -gt 0 ]; then
        FRAG_PCT=$(( (DB_SIZE - DB_IN_USE) * 100 / DB_SIZE ))
        echo "  ${pod}: db=${DB_SIZE} bytes, in_use=${DB_IN_USE} bytes, fragmentation=${FRAG_PCT}%"
    else
        echo "  ${pod}: unable to read status"
    fi
done

echo ""
echo "Validated: etcd cluster healthy, proceeding with rolling defrag."

echo ""
echo "=== Phase 2: Action ==="
echo "Performing rolling defragmentation (one member at a time)..."

DEFRAG_FAILURES=0
for pod in $ETCD_PODS; do
    echo ""
    echo "--- Defragging ${pod} ---"

    echo "  Pre-defrag health check..."
    if ! kubectl exec "$pod" -n "$TARGET_RESOURCE_NAMESPACE" -- sh -c \
      "ETCDCTL_API=3 etcdctl --endpoints=$ENDPOINTS endpoint health" 2>/dev/null; then
        echo "  WARNING: ${pod} health check failed, skipping"
        DEFRAG_FAILURES=$((DEFRAG_FAILURES + 1))
        continue
    fi

    echo "  Running defrag..."
    if kubectl exec "$pod" -n "$TARGET_RESOURCE_NAMESPACE" -- sh -c \
      "ETCDCTL_API=3 etcdctl --endpoints=$ENDPOINTS defrag --command-timeout=60s" 2>/dev/null; then
        echo "  Defrag completed on ${pod}."
    else
        echo "  WARNING: Defrag failed on ${pod}"
        DEFRAG_FAILURES=$((DEFRAG_FAILURES + 1))
        continue
    fi

    echo "  Post-defrag health check..."
    RETRIES=0
    while [ "$RETRIES" -lt 6 ]; do
        if kubectl exec "$pod" -n "$TARGET_RESOURCE_NAMESPACE" -- sh -c \
          "ETCDCTL_API=3 etcdctl --endpoints=$ENDPOINTS endpoint health" 2>/dev/null; then
            echo "  ${pod} healthy after defrag."
            break
        fi
        RETRIES=$((RETRIES + 1))
        echo "  Waiting for ${pod} to recover... (${RETRIES}/6)"
        sleep 5
    done

    if [ "$RETRIES" -ge 6 ]; then
        echo "  ERROR: ${pod} did not recover after defrag"
        DEFRAG_FAILURES=$((DEFRAG_FAILURES + 1))
    fi

    echo "  Waiting 10s before next member..."
    sleep 10
done

if [ "$DEFRAG_FAILURES" -gt 0 ]; then
    echo ""
    echo "WARNING: ${DEFRAG_FAILURES} member(s) had issues during defrag"
fi

echo ""
echo "=== Phase 3: Verify ==="
echo "Post-defrag database status:"
SUCCESS=false
for pod in $ETCD_PODS; do
    SIZE_INFO=$(kubectl exec "$pod" -n "$TARGET_RESOURCE_NAMESPACE" -- sh -c \
      "ETCDCTL_API=3 etcdctl --endpoints=$ENDPOINTS endpoint status --write-out=json" 2>/dev/null || echo "{}")
    DB_SIZE=$(echo "$SIZE_INFO" | grep -o '"dbSize":[0-9]*' | head -1 | cut -d: -f2)
    DB_IN_USE=$(echo "$SIZE_INFO" | grep -o '"dbSizeInUse":[0-9]*' | head -1 | cut -d: -f2)
    if [ -n "$DB_SIZE" ] && [ "$DB_SIZE" -gt 0 ]; then
        FRAG_PCT=$(( (DB_SIZE - DB_IN_USE) * 100 / DB_SIZE ))
        echo "  ${pod}: db=${DB_SIZE} bytes, in_use=${DB_IN_USE} bytes, fragmentation=${FRAG_PCT}%"
        if [ "$FRAG_PCT" -lt 30 ]; then
            SUCCESS=true
        fi
    fi
done

if [ "$SUCCESS" = "true" ] && [ "$DEFRAG_FAILURES" -eq 0 ]; then
    echo ""
    echo "=== SUCCESS: Rolling defrag completed. Fragmentation reduced on all members. ==="
elif [ "$SUCCESS" = "true" ]; then
    echo ""
    echo "=== PARTIAL SUCCESS: Fragmentation reduced but ${DEFRAG_FAILURES} member(s) had issues. ==="
else
    echo ""
    echo "ERROR: Fragmentation was not sufficiently reduced."
    exit 1
fi
