#!/usr/bin/env bash
# Cluster Autoscaling Demo -- Fleet Runner
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISIONER_PID=""
PROVISIONER_PID_FILE="$(mktemp -t kubernaut-autoscale-fleet-pid.XXXXXX)"
export FLEET_AUTOSCALE_PROVISIONER_PID_FILE="${PROVISIONER_PID_FILE}"
cleanup_provisioner() {
    if [ -n "${PROVISIONER_PID}" ]; then
        kill "${PROVISIONER_PID}" 2>/dev/null || true
    fi
    rm -f "${PROVISIONER_PID_FILE}"
}
trap cleanup_provisioner EXIT

# spoke.sh owns startup because it also computes capacity. Its detached
# process is recorded explicitly so it cannot keep a caller's log pipe open.
bash "${SCRIPT_DIR}/spoke.sh"
PROVISIONER_PID=$(cat "${PROVISIONER_PID_FILE}" 2>/dev/null || true)
bash "${SCRIPT_DIR}/hub.sh" "$@"
