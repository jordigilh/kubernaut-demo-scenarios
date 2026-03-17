#!/usr/bin/env bash
# Apply all RemediationWorkflow CRDs from deploy/remediation-workflows/.
# The DataStorage controller reconciles them into the workflow catalog.
#
# Usage:
#   ./scripts/seed-workflows.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_DIR="${SCRIPT_DIR}/../deploy/remediation-workflows"
NAMESPACE="${PLATFORM_NS:-kubernaut-system}"

echo "==> Applying RemediationWorkflow CRDs from ${WORKFLOWS_DIR}"
kubectl apply -R -f "${WORKFLOWS_DIR}/" -n "$NAMESPACE"
echo "==> Done. Verify: kubectl get remediationworkflows -n ${NAMESPACE}"
