#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo-operator}"
SUB_NAME="etcd"

CSV_NAME=$(kubectl get csv -n "${NAMESPACE}" --no-headers -o custom-columns=NAME:.metadata.name | grep "^etcd" | head -1)
if [ -z "${CSV_NAME}" ]; then
    echo "ERROR: No etcd CSV found in ${NAMESPACE}" >&2
    exit 1
fi

# Save original Subscription spec so the workflow can restore the correct
# CatalogSource reference after remediation.
SUB_JSON=$(kubectl get subscription.operators.coreos.com "${SUB_NAME}" -n "${NAMESPACE}" -o json 2>/dev/null || echo "")
if [ -n "${SUB_JSON}" ]; then
    PACKAGE=$(echo "$SUB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['spec']['name'])")
    CHANNEL=$(echo "$SUB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['spec']['channel'])")
    SOURCE=$(echo "$SUB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['spec']['source'])")
    SOURCE_NS=$(echo "$SUB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['spec'].get('sourceNamespace','openshift-marketplace'))")
    APPROVAL=$(echo "$SUB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['spec'].get('installPlanApproval','Automatic'))")

    echo "==> Saving original Subscription spec to ConfigMap..."
    kubectl create configmap operator-restore-spec -n "${NAMESPACE}" \
        --from-literal=subscription-name="${SUB_NAME}" \
        --from-literal=package="${PACKAGE}" \
        --from-literal=channel="${CHANNEL}" \
        --from-literal=source="${SOURCE}" \
        --from-literal=sourceNamespace="${SOURCE_NS}" \
        --from-literal=installPlanApproval="${APPROVAL}" \
        --from-literal=csvName="${CSV_NAME}" \
        --dry-run=client -o yaml | kubectl apply -f -
fi

echo "==> Deleting CSV ${CSV_NAME} to simulate operator failure..."
kubectl delete csv "${CSV_NAME}" -n "${NAMESPACE}"

# Corrupt the Subscription source so OLM cannot self-heal the CSV,
# but leave the Subscription in place so the LLM can read its spec.
echo "==> Corrupting Subscription source to prevent OLM self-healing..."
kubectl patch subscription.operators.coreos.com "${SUB_NAME}" -n "${NAMESPACE}" --type=merge \
    -p '{"spec":{"source":"removed-catalog"}}' 2>/dev/null || true

echo "==> Operator disrupted. CSV deleted, Subscription source corrupted."
echo "   csv_succeeded metric will drop to 0."
echo "   OLM cannot self-heal (CatalogSource does not exist)."
