#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../../scripts/fleet-validation-helper.sh"
fleet_validation_set_workload_namespaces demo-controllers
fleet_validate_local "${SCRIPT_DIR}/../validate.sh" "$@"
