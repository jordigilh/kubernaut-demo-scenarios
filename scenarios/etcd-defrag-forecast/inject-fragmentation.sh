#!/usr/bin/env bash
# Inject etcd fragmentation using the etcd v3 HTTP API via a UBI helper pod with curl.
# After writing keys, deletes them via etcdctl, compacts, and triggers a freelist
# flush so boltdb reports high fragmentation (dbSize >> dbSizeInUse).
set -euo pipefail

NAMESPACE="demo-etcd-defrag"
ETCD_URL="http://etcd-client.${NAMESPACE}.svc.cluster.local:2379"
KEY_PREFIX="/demo/fragmentation/key-"
KEY_COUNT=300
VALUE_SIZE=200000

echo "==> Injecting etcd fragmentation in ${NAMESPACE}..."
echo "    Target: ${KEY_COUNT} keys x $((VALUE_SIZE / 1024))KB = ~$((KEY_COUNT * VALUE_SIZE / 1024 / 1024)) MB"
echo ""

kubectl delete pod etcd-injector -n "${NAMESPACE}" --ignore-not-found 2>/dev/null
kubectl delete configmap etcd-inject-script -n "${NAMESPACE}" --ignore-not-found 2>/dev/null

cat > /tmp/etcd-inject-inner.sh <<INNEREOF
#!/bin/sh
set -e
ETCD_URL="${ETCD_URL}"
KEY_PREFIX="${KEY_PREFIX}"
KEY_COUNT=${KEY_COUNT}
VALUE_SIZE=${VALUE_SIZE}

# Generate value once and base64 encode it to a file
head -c \${VALUE_SIZE} /dev/urandom | base64 -w 0 > /tmp/val_b64.txt

echo "==> Phase 1: Writing \${KEY_COUNT} keys..."
i=0
while [ \$i -lt \$KEY_COUNT ]; do
    KEY_B64=\$(printf '%s' "\${KEY_PREFIX}\${i}" | base64 -w 0)
    # Build JSON payload file to avoid argument-list-too-long
    printf '{"key":"%s","value":"' "\${KEY_B64}" > /tmp/payload.json
    cat /tmp/val_b64.txt >> /tmp/payload.json
    printf '"}' >> /tmp/payload.json
    curl -s -o /dev/null "\${ETCD_URL}/v3/kv/put" \
        -H "Content-Type: application/json" \
        -d @/tmp/payload.json
    i=\$((i + 1))
    if [ \$((i % 100)) -eq 0 ]; then
        echo "    Written: \${i}/\${KEY_COUNT}"
    fi
done
echo "    Written: \${i}/\${KEY_COUNT} keys."

echo ""
echo "==> Phase 2: Write complete. Deletion will be handled externally via etcdctl."
INNEREOF

kubectl create configmap etcd-inject-script -n "${NAMESPACE}" \
    --from-file=inject.sh=/tmp/etcd-inject-inner.sh

echo "==> Starting injector pod (writing keys)..."
kubectl run etcd-injector -n "${NAMESPACE}" --rm -i --restart=Never \
    --image=registry.access.redhat.com/ubi9/ubi:latest \
    --overrides='{
      "spec": {
        "containers": [{
          "name": "etcd-injector",
          "image": "registry.access.redhat.com/ubi9/ubi:latest",
          "command": ["/bin/sh", "/scripts/inject.sh"],
          "volumeMounts": [{"name": "script", "mountPath": "/scripts"}],
          "securityContext": {
            "allowPrivilegeEscalation": false,
            "runAsNonRoot": true,
            "seccompProfile": {"type": "RuntimeDefault"},
            "capabilities": {"drop": ["ALL"]}
          }
        }],
        "volumes": [{"name": "script", "configMap": {"name": "etcd-inject-script", "defaultMode": 493}}]
      }
    }'

rm -f /tmp/etcd-inject-inner.sh

echo ""
echo "==> Phase 3: Deleting all keys via etcdctl..."
DELETED=$(kubectl exec etcd-0 -n "${NAMESPACE}" -- \
    etcdctl --endpoints=http://localhost:2379 del --prefix "${KEY_PREFIX}")
echo "    Deleted ${DELETED} keys."

echo ""
echo "==> Phase 4: Compacting to reclaim revision space..."
REV=$(kubectl exec etcd-0 -n "${NAMESPACE}" -- \
    etcdctl --endpoints=http://localhost:2379 endpoint status --write-out=json 2>/dev/null \
    | grep -o '"revision":[0-9]*' | head -1 | cut -d: -f2)
kubectl exec etcd-0 -n "${NAMESPACE}" -- \
    etcdctl --endpoints=http://localhost:2379 compact "${REV}"
echo "    Compacted to revision ${REV}."

echo ""
echo "==> Phase 5: Flushing boltdb freelist..."
kubectl exec etcd-0 -n "${NAMESPACE}" -- \
    etcdctl --endpoints=http://localhost:2379 put "/demo/freelist-flush" "done"
sleep 3

echo ""
echo "==> Fragmentation injection complete."
echo "    dbSize is large (from written data) but dbSizeInUse is tiny (all keys deleted)."
echo "    Fragmentation ratio should be >90%."
