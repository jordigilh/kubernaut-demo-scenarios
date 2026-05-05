#!/usr/bin/env bash
# Inject etcd fragmentation using the etcd v3 HTTP API via a UBI helper pod with curl.
set -euo pipefail

NAMESPACE="demo-etcd-defrag"
ETCD_URL="http://etcd-client.${NAMESPACE}.svc.cluster.local:2379"
KEY_PREFIX="/demo/fragmentation/key-"
KEY_COUNT=2000
VALUE_SIZE=500000

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
    if [ \$((i % 200)) -eq 0 ]; then
        echo "    Written: \${i}/\${KEY_COUNT}"
    fi
done
echo "    Written: \${i}/\${KEY_COUNT} keys."

echo ""
echo "==> Phase 2: Deleting all keys with prefix..."
PREFIX_B64=\$(printf '%s' "\${KEY_PREFIX}" | base64 -w 0)
# range_end for prefix delete: increment last byte of key prefix
RANGE_END=\$(printf '%s' "\${KEY_PREFIX}" | sed 's/.\$//'; printf '\\0'  | base64 -w 0)
curl -s "\${ETCD_URL}/v3/kv/deleterange" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"\${PREFIX_B64}\",\"range_end\":\"\${RANGE_END}\"}"
echo ""
echo "    All keys deleted."

echo ""
echo "==> Fragmentation injection complete."
INNEREOF

kubectl create configmap etcd-inject-script -n "${NAMESPACE}" \
    --from-file=inject.sh=/tmp/etcd-inject-inner.sh

echo "==> Starting injector pod..."
kubectl run etcd-injector -n "${NAMESPACE}" --rm -i --restart=Never \
    --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
    --overrides='{
      "spec": {
        "containers": [{
          "name": "etcd-injector",
          "image": "registry.access.redhat.com/ubi9/ubi-minimal:latest",
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
