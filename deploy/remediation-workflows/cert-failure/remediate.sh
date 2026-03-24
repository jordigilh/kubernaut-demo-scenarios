#!/bin/sh
set -e

: "${CERTIFICATE_NAME:?CERTIFICATE_NAME is required}"
: "${TARGET_RESOURCE_NAME:?TARGET_RESOURCE_NAME is required}"
: "${TARGET_RESOURCE_NAMESPACE:?TARGET_RESOURCE_NAMESPACE is required}"
: "${ISSUER_NAME:?ISSUER_NAME is required}"
: "${CA_SECRET_NAME:?CA_SECRET_NAME is required}"

echo "=== Phase 1: Validate ==="
echo "Checking Certificate ${CERTIFICATE_NAME} in ${TARGET_RESOURCE_NAMESPACE}..."

ACTUAL_CERT="${CERTIFICATE_NAME}"
CERT_READY=$(kubectl get certificate "${ACTUAL_CERT}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

if [ "${CERT_READY}" = "Unknown" ]; then
  echo "Certificate '${ACTUAL_CERT}' not found. Searching by secretName..."
  ACTUAL_CERT=$(kubectl get certificates -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath="{range .items[?(@.spec.secretName==\"${CERTIFICATE_NAME}\")]}{.metadata.name}{end}" 2>/dev/null || echo "")
  if [ -n "${ACTUAL_CERT}" ]; then
    echo "Resolved Certificate: ${ACTUAL_CERT} (from secretName=${CERTIFICATE_NAME})"
    CERT_READY=$(kubectl get certificate "${ACTUAL_CERT}" -n "${TARGET_RESOURCE_NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  else
    echo "ERROR: No Certificate found with name or secretName '${CERTIFICATE_NAME}' in ${TARGET_RESOURCE_NAMESPACE}"
    exit 1
  fi
fi

echo "Certificate Ready status: ${CERT_READY}"

if [ "${CERT_READY}" = "True" ]; then
  echo "Certificate is already Ready. No action needed."
  exit 0
fi

CERT_MESSAGE=$(kubectl get certificate "${ACTUAL_CERT}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "unknown")
echo "Certificate message: ${CERT_MESSAGE}"

ISSUER_READY=$(kubectl get clusterissuer "${ISSUER_NAME}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
echo "ClusterIssuer ${ISSUER_NAME} Ready status: ${ISSUER_READY}"

CA_EXISTS=$(kubectl get secret "${CA_SECRET_NAME}" -n "${CA_SECRET_NAMESPACE:-cert-manager}" \
  -o name 2>/dev/null || echo "missing")
echo "CA Secret: ${CA_EXISTS}"

if [ "${CA_EXISTS}" != "missing" ]; then
  echo "CA Secret exists. Issue may be different than expected."
  echo "Proceeding with CA regeneration anyway..."
fi

echo "Validated: Certificate is not Ready, CA Secret needs regeneration."

echo "=== Phase 2: Action ==="
echo "Generating new self-signed CA key pair..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${TMPDIR}/ca.key" -out "${TMPDIR}/ca.crt" \
  -days 365 -subj "/CN=Demo CA/O=Kubernaut"

echo "Creating CA Secret ${CA_SECRET_NAME} in ${CA_SECRET_NAMESPACE:-cert-manager}..."
kubectl create secret tls "${CA_SECRET_NAME}" \
  --cert="${TMPDIR}/ca.crt" --key="${TMPDIR}/ca.key" \
  -n "${CA_SECRET_NAMESPACE:-cert-manager}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Triggering certificate re-issuance..."
kubectl delete secret "$(kubectl get certificate "${ACTUAL_CERT}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.spec.secretName}')" -n "${TARGET_RESOURCE_NAMESPACE}" --ignore-not-found

sleep 5

echo "=== Phase 3: Verify ==="
echo "Waiting for Certificate to become Ready (up to 60s)..."
for i in $(seq 1 12); do
  CERT_READY=$(kubectl get certificate "${ACTUAL_CERT}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "${CERT_READY}" = "True" ]; then
    break
  fi
  sleep 5
done

echo "Certificate Ready status: ${CERT_READY}"
ISSUER_READY=$(kubectl get clusterissuer "${ISSUER_NAME}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
echo "ClusterIssuer Ready status: ${ISSUER_READY}"

if [ "${CERT_READY}" = "True" ]; then
  echo "=== SUCCESS: CA Secret recreated, Certificate ${ACTUAL_CERT} is now Ready ==="
else
  echo "ERROR: Certificate still not Ready after CA Secret recreation"
  exit 1
fi
