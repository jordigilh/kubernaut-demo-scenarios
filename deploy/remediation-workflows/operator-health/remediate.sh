#!/bin/sh
set -e

echo "=== Phase 1: Validate ==="

# The platform may pass Namespace/demo-operator (instead of Subscription/etcd)
# when the enrichment code encounters ambiguous API groups (e.g. Knative's
# messaging.knative.dev/Subscription vs operators.coreos.com/Subscription).
# Handle both cases by first checking for the operator-restore-spec ConfigMap.

NS="${TARGET_RESOURCE_NAMESPACE}"
SUB_NAME="${TARGET_RESOURCE_NAME}"

if [ "${TARGET_RESOURCE_KIND}" = "Namespace" ] || [ -z "${NS}" ]; then
    NS="${TARGET_RESOURCE_NAME}"
    SUB_NAME=""
    echo "Target is Namespace/${NS}; will derive Subscription from ConfigMap."
fi

PACKAGE=$(kubectl get configmap operator-restore-spec -n "$NS" -o jsonpath='{.data.package}' 2>/dev/null || echo "")

if [ -n "$PACKAGE" ]; then
    CHANNEL=$(kubectl get configmap operator-restore-spec -n "$NS" -o jsonpath='{.data.channel}')
    SOURCE=$(kubectl get configmap operator-restore-spec -n "$NS" -o jsonpath='{.data.source}')
    SOURCE_NS=$(kubectl get configmap operator-restore-spec -n "$NS" -o jsonpath='{.data.sourceNamespace}')
    INSTALL_MODE=$(kubectl get configmap operator-restore-spec -n "$NS" -o jsonpath='{.data.installPlanApproval}')
    CSV_NAME=$(kubectl get configmap operator-restore-spec -n "$NS" -o jsonpath='{.data.csvName}' 2>/dev/null || echo "")
    CM_SUB=$(kubectl get configmap operator-restore-spec -n "$NS" -o jsonpath='{.data.subscription-name}' 2>/dev/null || echo "")
    if [ -n "$CM_SUB" ]; then
        SUB_NAME="$CM_SUB"
    fi
    echo "Recovered spec from operator-restore-spec ConfigMap (sub=${SUB_NAME})."
else
    if [ -z "$SUB_NAME" ]; then
        echo "ERROR: No operator-restore-spec ConfigMap found in ${NS} and no Subscription name provided."
        exit 1
    fi
    PACKAGE=$(kubectl get subscription.operators.coreos.com "$SUB_NAME" -n "$NS" -o jsonpath='{.spec.name}' 2>/dev/null || echo "")
    if [ -n "$PACKAGE" ]; then
        CHANNEL=$(kubectl get subscription.operators.coreos.com "$SUB_NAME" -n "$NS" -o jsonpath='{.spec.channel}')
        SOURCE=$(kubectl get subscription.operators.coreos.com "$SUB_NAME" -n "$NS" -o jsonpath='{.spec.source}')
        SOURCE_NS=$(kubectl get subscription.operators.coreos.com "$SUB_NAME" -n "$NS" -o jsonpath='{.spec.sourceNamespace}')
        INSTALL_MODE=$(kubectl get subscription.operators.coreos.com "$SUB_NAME" -n "$NS" -o jsonpath='{.spec.installPlanApproval}')
        CSV_NAME=$(kubectl get subscription.operators.coreos.com "$SUB_NAME" -n "$NS" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
        echo "Using live Subscription spec."
    else
        echo "ERROR: Neither operator-restore-spec ConfigMap nor Subscription '${SUB_NAME}' found in ${NS}"
        exit 1
    fi
fi

echo "Subscription: ${SUB_NAME}"
echo "Package: ${PACKAGE}"
echo "Channel: ${CHANNEL}"
echo "CatalogSource: ${SOURCE} (${SOURCE_NS})"
echo "InstallPlanApproval: ${INSTALL_MODE:-Automatic}"
echo "Previous CSV: ${CSV_NAME:-<none>}"

echo "Validated: operator needs restoration."

echo "=== Phase 2: Action ==="

if kubectl get subscription.operators.coreos.com "$SUB_NAME" -n "$NS" >/dev/null 2>&1; then
    echo "Deleting current Subscription to reset OLM state..."
    kubectl delete subscription.operators.coreos.com "$SUB_NAME" -n "$NS" --wait=true
fi

if [ -n "$CSV_NAME" ]; then
    echo "Cleaning up old CSV ${CSV_NAME}..."
    kubectl delete csv "$CSV_NAME" -n "$NS" --ignore-not-found --wait=true
fi

echo "Recreating Subscription..."
cat <<EOSUB | kubectl apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUB_NAME}
  namespace: ${NS}
spec:
  channel: ${CHANNEL}
  name: ${PACKAGE}
  source: ${SOURCE}
  sourceNamespace: ${SOURCE_NS:-openshift-marketplace}
  installPlanApproval: ${INSTALL_MODE:-Automatic}
EOSUB

echo "=== Phase 3: Verify ==="
echo "Waiting for OLM to install operator CSV..."
TIMEOUT=300
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    NEW_CSV=$(kubectl get subscription.operators.coreos.com "$SUB_NAME" -n "$NS" \
      -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    if [ -n "$NEW_CSV" ]; then
        PHASE=$(kubectl get csv "$NEW_CSV" -n "$NS" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$PHASE" = "Succeeded" ]; then
            echo "=== SUCCESS: Operator restored. CSV ${NEW_CSV} phase: Succeeded ==="
            kubectl delete configmap operator-restore-spec -n "$NS" --ignore-not-found 2>/dev/null || true
            exit 0
        fi
        echo "  CSV ${NEW_CSV} phase: ${PHASE:-Pending}..."
    else
        IP_COUNT=$(kubectl get installplan -n "$NS" \
          -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
        echo "  Waiting for CSV... (${IP_COUNT} InstallPlans)"
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

echo "WARNING: CSV not fully installed within ${TIMEOUT}s"
exit 1
