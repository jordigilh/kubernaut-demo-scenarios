#!/usr/bin/env bash
# Run the existing first-cycle validator with workload assertions routed to the
# spoke and pipeline assertions routed to the hub.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/fleet-validation-helper.sh
source "${SCRIPT_DIR}/../../../scripts/fleet-validation-helper.sh"
fleet_validation_set_workload_namespaces demo-analytics
fleet_validate_local "${SCRIPT_DIR}/../validate.sh" "$@"
