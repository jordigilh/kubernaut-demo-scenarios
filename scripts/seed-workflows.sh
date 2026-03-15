#!/usr/bin/env bash
# Apply all RemediationWorkflow CRDs from scenario directories.
# The DataStorage controller reconciles them into the workflow catalog.
#
# Usage:
#   ./scripts/seed-workflows.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_DIR="${SCRIPT_DIR}/../scenarios"
NAMESPACE="${PLATFORM_NS:-kubernaut-system}"

echo "==> Applying RemediationWorkflow CRDs from ${SCENARIOS_DIR}"
kubectl apply -f "${SCENARIOS_DIR}"/*/workflow/ -n "$NAMESPACE"
echo "==> Done. Verify: kubectl get remediationworkflows -n ${NAMESPACE}"
