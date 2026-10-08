#!/usr/bin/env bash
# Compatibility entry point for GitOps Drift fleet cleanup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "${SCRIPT_DIR}/cleanup.sh" --fleet "$@"
