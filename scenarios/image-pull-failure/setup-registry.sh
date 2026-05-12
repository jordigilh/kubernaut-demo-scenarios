#!/usr/bin/env bash
# Setup OCP internal registry for the image-pull-failure scenario.
#
# Creates a private source namespace with an imported image and generates
# a dockerconfigjson secret that allows cross-namespace pulls. The secret
# is installed in both the demo namespace and kubernaut-workflows (as a
# template for the remediation workflow).
#
# Usage: source this file or run directly:
#   bash scenarios/image-pull-failure/setup-registry.sh
set -euo pipefail

SOURCE_NS="demo-imagepull-source"
DEMO_NS="${NAMESPACE:-demo-imagepull}"
WORKFLOW_NS="${WE_NAMESPACE:-kubernaut-workflows}"
REGISTRY="image-registry.openshift-image-registry.svc:5000"
UPSTREAM_IMAGE="registry.k8s.io/e2e-test-images/busybox:1.29-2"
IS_NAME="inventory-api"
IS_TAG="v1"
SA_NAME="image-puller"
SECRET_NAME="registry-credentials"
TEMPLATE_SECRET="registry-credentials-template"

echo "==> Setting up OCP internal registry for image-pull-failure..."

# 1. Create source namespace (demo namespace is created by kustomize)
if ! kubectl get namespace "$SOURCE_NS" &>/dev/null; then
    kubectl create namespace "$SOURCE_NS"
else
    echo "  Source namespace ${SOURCE_NS} already exists."
fi

# 2. Import a public image into the source namespace as an ImageStream
if ! kubectl get is "$IS_NAME" -n "$SOURCE_NS" &>/dev/null; then
    echo "  Importing ${UPSTREAM_IMAGE} into ${SOURCE_NS}/${IS_NAME}:${IS_TAG}..."
    oc import-image "${IS_NAME}:${IS_TAG}" \
        --from="$UPSTREAM_IMAGE" \
        --confirm \
        -n "$SOURCE_NS" >/dev/null
else
    echo "  ImageStream ${SOURCE_NS}/${IS_NAME} already exists."
fi

INTERNAL_IMAGE="${REGISTRY}/${SOURCE_NS}/${IS_NAME}:${IS_TAG}"
echo "  Internal image: ${INTERNAL_IMAGE}"

# 3. Create a ServiceAccount with cross-namespace pull access
if ! kubectl get sa "$SA_NAME" -n "$SOURCE_NS" &>/dev/null; then
    kubectl create sa "$SA_NAME" -n "$SOURCE_NS"
fi
oc policy add-role-to-user system:image-puller \
    "system:serviceaccount:${SOURCE_NS}:${SA_NAME}" \
    -n "$SOURCE_NS" >/dev/null 2>&1

# 4. Generate a long-lived token for the SA
TOKEN=$(oc create token "$SA_NAME" -n "$SOURCE_NS" --duration=87600h)

# 5. Create the dockerconfigjson secret in the demo namespace
kubectl delete secret "$SECRET_NAME" -n "$DEMO_NS" --ignore-not-found >/dev/null 2>&1
kubectl create secret docker-registry "$SECRET_NAME" \
    --docker-server="$REGISTRY" \
    --docker-username="$SA_NAME" \
    --docker-password="$TOKEN" \
    -n "$DEMO_NS"
echo "  Secret ${SECRET_NAME} created in ${DEMO_NS}."

# 6. Store a template copy in the workflow namespace for the remediation
#    workflow to read when recreating the secret.
kubectl delete secret "$TEMPLATE_SECRET" -n "$WORKFLOW_NS" --ignore-not-found >/dev/null 2>&1
kubectl create secret docker-registry "$TEMPLATE_SECRET" \
    --docker-server="$REGISTRY" \
    --docker-username="$SA_NAME" \
    --docker-password="$TOKEN" \
    -n "$WORKFLOW_NS"
echo "  Template secret ${TEMPLATE_SECRET} created in ${WORKFLOW_NS}."

echo "==> OCP internal registry setup complete."
