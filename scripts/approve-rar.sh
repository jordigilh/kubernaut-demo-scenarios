#!/usr/bin/env bash
# Approve a named or the most recent pending RemediationApprovalRequest.
# Usage: bash scripts/approve-rar.sh [-h] [-kubeconfig PATH] [RAR_NAME]
set -euo pipefail

PLATFORM_NS="${PLATFORM_NS:-kubernaut-system}"
RAR_NAME=""
KUBECONFIG_PATH=""

usage() {
  cat <<'EOF'
Usage: bash scripts/approve-rar.sh [-h] [-kubeconfig PATH] [RAR_NAME]

Approve a RemediationApprovalRequest in the kubernaut platform namespace.
If RAR_NAME is omitted, the most recent RAR is selected.

Options:
  -h                  Show this help.
  -kubeconfig PATH    Use PATH for kubectl instead of KUBECONFIG/default config.

Examples:
  ./scripts/approve-rar.sh rar-rr-324324-3258437
  ./scripts/approve-rar.sh -kubeconfig /path/to/hub-kubeconfig rar-rr-324324-3258437
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -kubeconfig|--kubeconfig)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: $1 requires a kubeconfig path" >&2
        usage >&2
        exit 2
      fi
      KUBECONFIG_PATH="$2"
      shift 2
      ;;
    -kubeconfig=*|--kubeconfig=*)
      KUBECONFIG_PATH="${1#*=}"
      if [ -z "$KUBECONFIG_PATH" ]; then
        echo "ERROR: $1 requires a kubeconfig path" >&2
        usage >&2
        exit 2
      fi
      shift
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$RAR_NAME" ]; then
        echo "ERROR: only one RAR_NAME may be provided" >&2
        usage >&2
        exit 2
      fi
      RAR_NAME="$1"
      shift
      ;;
  esac
done

KUBECTL_ARGS=()
if [ -n "$KUBECONFIG_PATH" ]; then
  KUBECTL_ARGS+=(--kubeconfig "$KUBECONFIG_PATH")
fi

if [ -z "$RAR_NAME" ]; then
  RAR_NAME=$(kubectl "${KUBECTL_ARGS[@]}" get remediationapprovalrequests -n "$PLATFORM_NS" \
    -o jsonpath='{.items[-1].metadata.name}')
fi

if [ -z "$RAR_NAME" ]; then
  echo "==> No RemediationApprovalRequest found in ${PLATFORM_NS}"
  exit 1
fi

echo "==> Approving RAR: $RAR_NAME"

kubectl "${KUBECTL_ARGS[@]}" patch remediationapprovalrequest "$RAR_NAME" -n "$PLATFORM_NS" \
  --subresource=status --type=merge \
  -p '{"status":{"decision":"Approved","decidedBy":"demo-operator","decisionMessage":"Approved for demo"}}'

echo "==> RAR approved."
