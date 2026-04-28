#!/usr/bin/env bash
# Inject a bad release to trigger CrashLoopBackOff.
# Overrides the container command so the app exits immediately on startup,
# simulating a broken binary/release. The previous deployment revision
# (without the command override) is the rollback target.
set -euo pipefail

NAMESPACE="demo-crashloop"

echo "==> Simulating bad release (command override)..."
kubectl patch deployment worker -n "${NAMESPACE}" --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/command","value":["sh","-c","echo fatal: bad release 1.1.0 -- aborting && exit 1"]}]'

echo "==> Bad release injected. New pods will exit immediately with code 1."
echo "     The previous revision (without command override) is the rollback target."
