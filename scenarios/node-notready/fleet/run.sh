#!/usr/bin/env bash
# Node NotReady Demo -- Fleet Runner
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/spoke.sh"
bash "${SCRIPT_DIR}/hub.sh" "$@"
