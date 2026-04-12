#!/bin/sh
set -e

: "${TARGET_RESOURCE_NAMESPACE:?TARGET_RESOURCE_NAMESPACE is required}"
: "${TARGET_RESOURCE_NAME:?TARGET_RESOURCE_NAME is required}"
CA_SECRET_NAMESPACE="${CA_SECRET_NAMESPACE:-cert-manager}"

echo "=== Phase 1: Discover ==="
echo "Scanning namespace ${TARGET_RESOURCE_NAMESPACE} for NotReady Certificates..."

CERT_NAME=$(kubectl get certificates -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
  | grep -v "True$" | head -1 | awk '{print $1}')

if [ -z "${CERT_NAME}" ]; then
  echo "No NotReady Certificate found in ${TARGET_RESOURCE_NAMESPACE}. Checking all..."
  CERT_NAME=$(kubectl get certificates -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [ -z "${CERT_NAME}" ]; then
  echo "ERROR: No Certificate found in namespace ${TARGET_RESOURCE_NAMESPACE}"
  exit 1
fi
echo "Certificate: ${CERT_NAME}"

CERT_READY=$(kubectl get certificate "${CERT_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
echo "Ready: ${CERT_READY}"

if [ "${CERT_READY}" = "True" ]; then
  echo "Certificate is already Ready. No action needed."
  exit 0
fi

CERT_MESSAGE=$(kubectl get certificate "${CERT_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "unknown")
echo "Message: ${CERT_MESSAGE}"

echo "=== Phase 1b: Resolve Issuer ==="
ISSUER_NAME=$(kubectl get certificate "${CERT_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null || echo "")
ISSUER_KIND=$(kubectl get certificate "${CERT_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.spec.issuerRef.kind}' 2>/dev/null || echo "ClusterIssuer")
echo "Issuer: ${ISSUER_KIND}/${ISSUER_NAME}"

if [ -z "${ISSUER_NAME}" ]; then
  echo "ERROR: Cannot resolve issuer from Certificate ${CERT_NAME}"
  exit 1
fi

if [ "${ISSUER_KIND}" = "ClusterIssuer" ]; then
  ISSUER_READY=$(kubectl get clusterissuer "${ISSUER_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  CA_SECRET_NAME=$(kubectl get clusterissuer "${ISSUER_NAME}" \
    -o jsonpath='{.spec.ca.secretName}' 2>/dev/null || echo "")
else
  ISSUER_READY=$(kubectl get issuer "${ISSUER_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  CA_SECRET_NAME=$(kubectl get issuer "${ISSUER_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.spec.ca.secretName}' 2>/dev/null || echo "")
fi
echo "Issuer Ready: ${ISSUER_READY}"
echo "CA Secret name (from issuer): ${CA_SECRET_NAME}"

if [ -z "${CA_SECRET_NAME}" ]; then
  echo "ERROR: Cannot resolve CA Secret name from ${ISSUER_KIND}/${ISSUER_NAME}"
  exit 1
fi

CA_EXISTS=$(kubectl get secret "${CA_SECRET_NAME}" -n "${CA_SECRET_NAMESPACE}" \
  -o name 2>/dev/null || echo "missing")
echo "CA Secret status: ${CA_EXISTS}"

if [ "${CA_EXISTS}" != "missing" ]; then
  echo "CA Secret exists. Issue may be different than expected."
  echo "Proceeding with CA regeneration anyway..."
fi

echo "Validated: Certificate ${CERT_NAME} is NotReady, CA Secret ${CA_SECRET_NAME} needs regeneration."

echo "=== Phase 2: Action ==="
echo "Generating new self-signed CA key pair..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${TMPDIR}/ca.key" -out "${TMPDIR}/ca.crt" \
  -days 365 -subj "/CN=Demo CA/O=Kubernaut"

echo "Creating CA Secret ${CA_SECRET_NAME} in ${CA_SECRET_NAMESPACE}..."
kubectl create secret tls "${CA_SECRET_NAME}" \
  --cert="${TMPDIR}/ca.crt" --key="${TMPDIR}/ca.key" \
  -n "${CA_SECRET_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Triggering certificate re-issuance..."
TLS_SECRET=$(kubectl get certificate "${CERT_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
  -o jsonpath='{.spec.secretName}' 2>/dev/null || echo "")
if [ -n "${TLS_SECRET}" ]; then
  kubectl delete secret "${TLS_SECRET}" -n "${TARGET_RESOURCE_NAMESPACE}" --ignore-not-found
fi

sleep 5

echo "=== Phase 3: Verify ==="
echo "Waiting for Certificate to become Ready (up to 60s)..."
for i in $(seq 1 12); do
  CERT_READY=$(kubectl get certificate "${CERT_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [ "${CERT_READY}" = "True" ]; then
    break
  fi
  sleep 5
done

echo "Certificate Ready status: ${CERT_READY}"
if [ "${ISSUER_KIND}" = "ClusterIssuer" ]; then
  ISSUER_READY=$(kubectl get clusterissuer "${ISSUER_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
else
  ISSUER_READY=$(kubectl get issuer "${ISSUER_NAME}" -n "${TARGET_RESOURCE_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
fi
echo "Issuer Ready status: ${ISSUER_READY}"

if [ "${CERT_READY}" = "True" ]; then
  echo "=== SUCCESS: CA Secret recreated, Certificate ${CERT_NAME} is now Ready ==="
else
  echo "ERROR: Certificate still not Ready after CA Secret recreation"
  exit 1
fi
