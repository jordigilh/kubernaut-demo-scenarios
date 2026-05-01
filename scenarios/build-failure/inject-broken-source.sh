#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="demo-build"

if ! command -v oc &>/dev/null; then
    echo "ERROR: oc is required for OpenShift build scenarios" >&2
    exit 1
fi

echo "==> Patching BuildConfig to reference non-existent repository..."
kubectl patch buildconfig webapp -n "${NAMESPACE}" --type=merge \
  -p '{"spec":{"source":{"git":{"uri":"https://github.com/sclorg/does-not-exist.git"}}}}'

echo "==> Starting a new build with broken source..."
oc start-build webapp -n "${NAMESPACE}"

echo "==> Build will fail with 'repository not found' error."
