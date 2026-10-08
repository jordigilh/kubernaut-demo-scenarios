#!/usr/bin/env bash
# Scenario orchestrator -- chains run.sh + validate.sh + cleanup.sh
#
# Usage:
#   ./scripts/run-scenario.sh --scenario hpa-maxed
#   ./scripts/run-scenario.sh --scenario hpa-maxed --auto-approve --cleanup
#   ./scripts/run-scenario.sh --scenario hpa-maxed,stuck-rollout
#   ./scripts/run-scenario.sh --validate-only --scenario hpa-maxed
#   ./scripts/run-scenario.sh --fleet --scenario hpa-maxed
#   ./scripts/run-scenario.sh --list
#
# Flags:
#   --scenario NAME[,NAME]   One or more scenarios (comma-separated)
#   --auto-approve           Auto-approve RemediationApprovalRequests (default)
#   --interactive            Pause for manual RAR approval
#   --alert-only             Deploy fault and stop once the alert fires (skip validation)
#   --cleanup                Run cleanup.sh after each successful scenario
#                            (failed scenarios are preserved for RCA)
#   --validate-only          Skip run.sh, only validate (scenario already deployed)
#   --skip-run               Alias for --validate-only
#   --fleet                  Run workload on SPOKE_KUBECONFIG and control plane on HUB_KUBECONFIG
#   --no-color               Disable color output
#   --timeout SECONDS        Pipeline timeout per scenario (default: 600)
#   --list                   List available scenarios and exit
#   --help                   Show this help
set -euo pipefail

# Save original argv for platform-helper.sh stdbuf re-exec (args are
# consumed by the parsing loop below, so $@ would be empty by the time
# platform-helper.sh is sourced).
printf -v _KUBERNAUT_ORIG_ARGV '%q ' "$0" "$@"
export _KUBERNAUT_ORIG_ARGV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCENARIOS_DIR="${REPO_ROOT}/scenarios"

# shellcheck source=fleet-helper.sh
source "${SCRIPT_DIR}/fleet-helper.sh"

# Defaults
SCENARIO_LIST=""
APPROVE_MODE="--auto-approve"
RUN_MODE="--auto-approve"
ALERT_ONLY=false
DO_CLEANUP=false
VALIDATE_ONLY=false
PIPELINE_TIMEOUT=600
NO_COLOR_FLAG=""
FLEET_MODE=false
DS_PORT_FORWARD_PID=""
DS_PORT_FORWARD_LOG=""
DS_PORT_FORWARD_PORT=""
PROM_PORT_FORWARD_PID=""
PROM_PORT_FORWARD_LOG=""
PROM_PORT_FORWARD_PORT=""

usage() {
    sed -n '2,/^set /{ /^#/s/^# \?//p }' "$0"
    exit 0
}

cleanup_port_forward() {
    if [ -n "$DS_PORT_FORWARD_PID" ]; then
        kill "$DS_PORT_FORWARD_PID" 2>/dev/null || true
        wait "$DS_PORT_FORWARD_PID" 2>/dev/null || true
        DS_PORT_FORWARD_PID=""
    fi
    if [ -n "$PROM_PORT_FORWARD_PID" ]; then
        kill "$PROM_PORT_FORWARD_PID" 2>/dev/null || true
        wait "$PROM_PORT_FORWARD_PID" 2>/dev/null || true
        PROM_PORT_FORWARD_PID=""
    fi
    [ -z "$DS_PORT_FORWARD_LOG" ] || rm -f "$DS_PORT_FORWARD_LOG"
    [ -z "$PROM_PORT_FORWARD_LOG" ] || rm -f "$PROM_PORT_FORWARD_LOG"
}
trap cleanup_port_forward EXIT

# Read a scenario's scenario.toml (if any); prints "fleet kind ocp" values.
read_scenario_meta() {
    local dir="$1" toml="$1/scenario.toml" out
    [ -f "$toml" ] || return 0
    out=$(python3 - "$toml" <<'PYEOF'
import sys, tomllib
try:
    d = tomllib.load(open(sys.argv[1], "rb"))
except Exception as e:
    sys.exit(1)
p = d.get("platforms", {})
kind = p.get("kind", "?")
host = p.get("host", "all")
if kind == "yes" and host not in ("all", "?"):
    kind = f"{kind}({host})"
print("%s %s %s" % (p.get("fleet", "?"), kind, p.get("ocp", "?")))
PYEOF
    ) || return 0
    printf "%s" "$out"
}

list_scenarios() {
    echo "Available scenarios:"
    echo ""
    for dir in "${SCENARIOS_DIR}"/*/; do
        local name
        name=$(basename "$dir")
        local has_run="" has_validate="" has_cleanup=""
        [ -f "${dir}/run.sh" ] && has_run="run"
        [ -f "${dir}/validate.sh" ] && has_validate="validate"
        [ -f "${dir}/cleanup.sh" ] && has_cleanup="cleanup"
        local meta
        meta=$(read_scenario_meta "${dir%/}")
        if [ -n "$meta" ]; then
            local fleet="" mkind="" mocp=""
            read -r fleet mkind mocp <<< "$meta"
            printf "  %-28s  [fleet=%-10s kind=%-10s ocp=%-7s]\n" "$name" "$fleet" "$mkind" "$mocp"
        elif [ -n "$has_run$has_validate$has_cleanup" ]; then
            printf "  %-28s  [%s]\n" "$name" "${has_run:+run }${has_validate:+validate }${has_cleanup:+cleanup}"
        fi
    done
    echo ""
}

# ── Parse arguments ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)
            SCENARIO_LIST="$2"
            shift 2
            ;;
        --auto-approve)
            APPROVE_MODE="--auto-approve"
            RUN_MODE="--auto-approve"
            shift
            ;;
        --interactive)
            APPROVE_MODE="--interactive"
            RUN_MODE="--interactive"
            shift
            ;;
        --alert-only)
            ALERT_ONLY=true
            RUN_MODE="--alert-only"
            shift
            ;;
        --cleanup)
            DO_CLEANUP=true
            shift
            ;;
        --validate-only|--skip-run)
            VALIDATE_ONLY=true
            shift
            ;;
        --no-color)
            export NO_COLOR=1
            NO_COLOR_FLAG="--no-color"
            shift
            ;;
        --fleet)
            FLEET_MODE=true
            shift
            ;;
        --timeout)
            PIPELINE_TIMEOUT="$2"
            shift 2
            ;;
        --list)
            list_scenarios
            exit 0
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1 (try --help)"
            exit 1
            ;;
    esac
done

if [ -z "$SCENARIO_LIST" ]; then
    echo "ERROR: --scenario is required (or use --list to see available scenarios)"
    exit 1
fi

if [ "$FLEET_MODE" = true ]; then
    fleet_dispatch_requested --fleet
    export KUBECONFIG="${HUB_KUBECONFIG}"
else
    # Respect user-provided KUBECONFIG; fall back to the demo kubeconfig.
    export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kubernaut-demo-config}"
fi

if [ "$ALERT_ONLY" = true ] && [ "$VALIDATE_ONLY" = true ]; then
    echo "ERROR: --alert-only and --validate-only are mutually exclusive"
    exit 1
fi

# Source color support
source "${SCRIPT_DIR}/validation-helper.sh"

# Pre-flight: verify demo environment is set up
# shellcheck source=platform-helper.sh
source "${SCRIPT_DIR}/platform-helper.sh"
require_demo_ready

# ── Port-forward management ──────────────────────────────────────────────────

# Select a free IPv4 loopback port. Kind/Podman commonly reserves host ports
# such as 30081 and 9090, so fixed local ports are not portable across macOS
# and Linux hosts. A caller-supplied preferred port is used when available;
# otherwise the kernel chooses an ephemeral port.
choose_local_port() {
    local preferred="${1:-}"
    if [ -n "$preferred" ] && python3 - "$preferred" <<'PY' >/dev/null 2>&1
import socket
import sys

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", int(sys.argv[1])))
PY
    then
        printf '%s\n' "$preferred"
        return 0
    fi

    python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

ensure_datastorage_port_forward() {
    if curl -sf -o /dev/null --connect-timeout 2 "http://127.0.0.1:30081/healthz" 2>/dev/null; then
        DS_PORT_FORWARD_PORT=30081
        return 0
    fi

    # DataStorage exposes TLS on port 8080 (API) and plaintext on 8081 (health).
    # Forward the health port so the readiness check works without TLS. Prefer
    # 30081 for continuity, but avoid fixed-port collisions with Kind/Podman.
    DS_PORT_FORWARD_PORT=$(choose_local_port "${DATASTORAGE_LOCAL_PORT:-30081}") || {
        log_error "Could not select a local port for DataStorage port-forward"
        return 1
    }
    DS_PORT_FORWARD_LOG=$(mktemp "${TMPDIR:-/tmp}/kubernaut-datastorage.XXXXXX")
    log_phase "Starting DataStorage port-forward (127.0.0.1:${DS_PORT_FORWARD_PORT} -> svc/data-storage-service:8081)..."
    kubectl port-forward --address=127.0.0.1 -n kubernaut-system \
        svc/data-storage-service "${DS_PORT_FORWARD_PORT}:8081" \
        >"${DS_PORT_FORWARD_LOG}" 2>&1 &
    DS_PORT_FORWARD_PID=$!

    local retries=0
    while [ "$retries" -lt 15 ]; do
        if curl -sf -o /dev/null --connect-timeout 1 \
            "http://127.0.0.1:${DS_PORT_FORWARD_PORT}/healthz" 2>/dev/null; then
            log_success "DataStorage port-forward ready"
            return 0
        fi
        sleep 1
        retries=$((retries + 1))
    done

    if [ -s "${DS_PORT_FORWARD_LOG}" ]; then
        sed 's/^/  /' "${DS_PORT_FORWARD_LOG}" >&2
    fi
    log_error "Failed to establish DataStorage port-forward"
    return 1
}

ensure_prometheus_port_forward() {
    if curl -sf -o /dev/null --connect-timeout 2 "http://127.0.0.1:9090/-/ready" 2>/dev/null; then
        PROM_PORT_FORWARD_PORT=9090
        return 0
    fi

    local prometheus_target
    prometheus_target=$(kubectl get svc -n monitoring -l operated-prometheus=true \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    prometheus_target="${prometheus_target:-kube-prometheus-stack-prometheus}"
    PROM_PORT_FORWARD_PORT=$(choose_local_port "${PROMETHEUS_LOCAL_PORT:-9090}") || {
        log_warn "Could not select a local port for Prometheus port-forward (non-critical)"
        return 0
    }
    PROM_PORT_FORWARD_LOG=$(mktemp "${TMPDIR:-/tmp}/kubernaut-prometheus.XXXXXX")
    log_phase "Starting Prometheus port-forward (127.0.0.1:${PROM_PORT_FORWARD_PORT} -> svc/${prometheus_target}:9090)..."
    kubectl port-forward --address=127.0.0.1 -n monitoring \
        "svc/${prometheus_target}" "${PROM_PORT_FORWARD_PORT}:9090" \
        >"${PROM_PORT_FORWARD_LOG}" 2>&1 &
    PROM_PORT_FORWARD_PID=$!

    local retries=0
    while [ "$retries" -lt 10 ]; do
        if curl -sf -o /dev/null --connect-timeout 1 \
            "http://127.0.0.1:${PROM_PORT_FORWARD_PORT}/-/ready" 2>/dev/null; then
            log_success "Prometheus port-forward ready"
            return 0
        fi
        sleep 1
        retries=$((retries + 1))
    done

    if [ -s "${PROM_PORT_FORWARD_LOG}" ]; then
        sed 's/^/  /' "${PROM_PORT_FORWARD_LOG}" >&2
    fi
    kill "$PROM_PORT_FORWARD_PID" 2>/dev/null || true
    wait "$PROM_PORT_FORWARD_PID" 2>/dev/null || true
    PROM_PORT_FORWARD_PID=""
    rm -f "$PROM_PORT_FORWARD_LOG"
    PROM_PORT_FORWARD_LOG=""
    log_warn "Prometheus port-forward may not be ready (non-critical)"
}

# ── Run scenarios ────────────────────────────────────────────────────────────

IFS=',' read -ra SCENARIOS <<< "$SCENARIO_LIST"

RESULTS=()
TOTAL_START=$(date +%s)

# Ensure port-forwards before any scenario
ensure_datastorage_port_forward
ensure_prometheus_port_forward

for scenario in "${SCENARIOS[@]}"; do
    scenario=$(echo "$scenario" | tr -d ' ')  # trim whitespace
    scenario_dir="${SCENARIOS_DIR}/${scenario}"

    if [ ! -d "$scenario_dir" ]; then
        echo "ERROR: Scenario '${scenario}' not found at ${scenario_dir}"
        RESULTS+=("${scenario}:ERROR:0")
        continue
    fi

    if [ "$FLEET_MODE" = true ] && [ ! -f "${scenario_dir}/fleet/run.sh" ]; then
        echo "ERROR: Scenario '${scenario}' has no fleet runner"
        RESULTS+=("${scenario}:ERROR:0")
        continue
    fi

    echo ""
    echo "  ${_c_bold}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_c_reset}"
    echo "  ${_c_bold}  Scenario: ${scenario}${_c_reset}"
    echo "  ${_c_bold}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_c_reset}"
    echo ""

    SCENARIO_START=$(date +%s)
    scenario_result="PASS"

    # Step 1: run.sh (unless --validate-only)
    # Pass --no-validate so run.sh doesn't chain into validate.sh itself
    # (run-scenario.sh calls validate.sh separately in Step 2).
    if [ "$VALIDATE_ONLY" = false ]; then
        if [ -f "${scenario_dir}/run.sh" ]; then
            log_phase "Running ${scenario}/run.sh..."
            run_args=(--no-validate "$RUN_MODE")
            if [ "$FLEET_MODE" = true ]; then
                run_args+=(--fleet)
            fi
            if ! bash "${scenario_dir}/run.sh" "${run_args[@]}"; then
                log_error "run.sh failed for ${scenario}"
                scenario_result="FAIL"
            fi
        else
            log_error "No run.sh found for ${scenario}"
            scenario_result="SKIP"
        fi
    else
        log_phase "Skipping run.sh (--validate-only)"
    fi

    # Step 2: validate.sh
    if [ "$ALERT_ONLY" = true ]; then
        log_warn "Skipping validate.sh (--alert-only: stopping once the alert fires)"
    elif [ "$scenario_result" != "FAIL" ]; then
        validation_script="${scenario_dir}/validate.sh"
        validation_label="validate.sh"
        if [ "$FLEET_MODE" = true ]; then
            validation_script="${scenario_dir}/fleet/validate.sh"
            validation_label="fleet/validate.sh"
        fi
            if [ -f "$validation_script" ]; then
                log_phase "Running ${scenario}/${validation_label}..."
                reset_assertions
                validate_args=("$APPROVE_MODE")
                if [ "$FLEET_MODE" = true ]; then
                    validate_args+=(--fleet)
                fi
                [ -n "$NO_COLOR_FLAG" ] && validate_args+=("$NO_COLOR_FLAG")
                # run.sh was invoked with --no-validate above, so the validator
                # owns the pipeline wait and must not be told that the Fleet
                # runner already processed it. That flag is only appropriate
                # when a direct scenario invocation has already driven the
                # complete pipeline before calling a second validator.
                if ! bash "$validation_script" "${validate_args[@]}"; then
                    scenario_result="FAIL"
                fi
        else
            log_warn "No validate.sh found for ${scenario} -- skipping validation"
            scenario_result="SKIP"
        fi
    fi

    SCENARIO_END=$(date +%s)
    SCENARIO_DURATION=$((SCENARIO_END - SCENARIO_START))

    RESULTS+=("${scenario}:${scenario_result}:${SCENARIO_DURATION}")

    # Step 3: cleanup.sh (if --cleanup and the scenario passed). Preserve
    # failed scenario resources so pods, events, workload state, and Helm
    # history remain available for RCA. Invoke the scenario cleanup.sh
    # manually when teardown of a failed run is desired.
    if [ "$DO_CLEANUP" = true ]; then
        if [ "$scenario_result" = "PASS" ] && [ -f "${scenario_dir}/cleanup.sh" ]; then
            log_phase "Running ${scenario}/cleanup.sh..."
            cleanup_args=()
            [ "$FLEET_MODE" = true ] && cleanup_args+=(--fleet)
            bash "${scenario_dir}/cleanup.sh" "${cleanup_args[@]}" || true
        elif [ "$scenario_result" = "FAIL" ]; then
            log_warn "Preserving ${scenario} resources after failure for RCA (cleanup skipped)"
        fi
    fi
done

# ── Summary table ────────────────────────────────────────────────────────────

TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - TOTAL_START))

echo ""
echo "  ${_c_bold}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_c_reset}"
echo "  ${_c_bold}  Summary${_c_reset}"
echo "  ${_c_bold}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_c_reset}"
echo ""
printf "  %-30s  %-8s  %s\n" "Scenario" "Result" "Duration"
printf "  %-30s  %-8s  %s\n" "──────────────────────────────" "────────" "────────"

PASS_COUNT=0
FAIL_COUNT=0

for entry in "${RESULTS[@]}"; do
    IFS=':' read -r name result duration <<< "$entry"
    local_mins=$((duration / 60))
    local_secs=$((duration % 60))
    duration_str=$(printf "%dm %02ds" "$local_mins" "$local_secs")

    case "$result" in
        PASS)
            result_color="${_c_green}"
            PASS_COUNT=$((PASS_COUNT + 1))
            ;;
        FAIL|ERROR)
            result_color="${_c_red}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            ;;
        *)
            result_color="${_c_yellow}"
            ;;
    esac

    printf "  %-30s  %s%-8s%s  %s\n" "$name" "$result_color" "$result" "$_c_reset" "$duration_str"
done

total_mins=$((TOTAL_DURATION / 60))
total_secs=$((TOTAL_DURATION % 60))
echo ""
printf "  Total: %dm %02ds | %s%d passed%s, %s%d failed%s\n" \
    "$total_mins" "$total_secs" \
    "$_c_green" "$PASS_COUNT" "$_c_reset" \
    "$_c_red" "$FAIL_COUNT" "$_c_reset"
echo ""

# Exit with failure if any scenario failed
[ "$FAIL_COUNT" -eq 0 ]
