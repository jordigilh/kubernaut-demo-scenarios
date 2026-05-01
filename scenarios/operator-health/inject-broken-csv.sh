#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="demo-operator"

CSV_NAME=$(kubectl get csv -n "${NAMESPACE}" --no-headers -o custom-columns=NAME:.metadata.name | grep "^etcd" | head -1)
if [ -z "${CSV_NAME}" ]; then
    echo "ERROR: No etcd CSV found in ${NAMESPACE}" >&2
    exit 1
fi

echo "==> Deleting CSV ${CSV_NAME} to simulate operator failure..."
kubectl delete csv "${CSV_NAME}" -n "${NAMESPACE}"

echo "==> CSV deleted. Operator will stop reconciling."
echo "   csv_succeeded metric will drop to 0."
