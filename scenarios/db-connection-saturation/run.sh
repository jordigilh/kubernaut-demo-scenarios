#!/usr/bin/env bash
# Database Connection Saturation Demo -- Automated Runner
# L3 Performance Management: Deep investigation of connection pool exhaustion.
#
# A connection-leaker deployment opens persistent psql sessions to PostgreSQL
# without releasing them (~1 every 8s). With max_connections=15, the pool
# saturates within ~2 minutes. The LLM must trace from the exhaustion alert
# to identify the leaker as the root cause and restart it.
#
# Prerequisites:
#   - OCP cluster with Kubernaut services
#   - Prometheus scraping via ServiceMonitor (postgres_exporter sidecar)
#
# Usage: ./scenarios/db-connection-saturation/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-db-saturation"

APPROVE_MODE="--auto-approve"
SKIP_VALIDATE=""
for _arg in "$@"; do
    case "$_arg" in
        --auto-approve)  APPROVE_MODE="--auto-approve" ;;
        --interactive)   APPROVE_MODE="--interactive" ;;
        --no-validate)   SKIP_VALIDATE=true ;;
    esac
done

# shellcheck source=../../scripts/platform-helper.sh
source "${SCRIPT_DIR}/../../scripts/platform-helper.sh"
require_demo_ready
# shellcheck source=../../scripts/validation-helper.sh
source "${SCRIPT_DIR}/../../scripts/validation-helper.sh"

echo "============================================="
echo " Database Connection Saturation Demo (L3)"
echo "============================================="
echo ""

# Enable KA Prometheus toolset so the LLM can query connection metrics.
echo "==> Enabling Kubernaut Agent Prometheus toolset for this scenario..."
enable_prometheus_toolset
echo ""

ensure_clean_slate "${NAMESPACE}"

# Step 1: Deploy scenario resources
echo "==> Step 1: Deploying scenario resources..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for PostgreSQL to be healthy
echo "==> Step 2: Waiting for postgres to be ready..."
kubectl wait --for=condition=Available deployment/postgres \
  -n "${NAMESPACE}" --timeout=180s
echo "  postgres is running with max_connections=15."

# Step 3: Wait for app workloads
echo "==> Step 3: Waiting for app workloads to be ready..."
kubectl wait --for=condition=Available deployment/order-service \
  -n "${NAMESPACE}" --timeout=120s
kubectl wait --for=condition=Available deployment/report-generator \
  -n "${NAMESPACE}" --timeout=120s
kubectl wait --for=condition=Available deployment/connection-leaker \
  -n "${NAMESPACE}" --timeout=120s
echo "  All workloads running."
kubectl get pods -n "${NAMESPACE}"
echo ""

# Step 4: Verify exporter is scraping
echo "==> Step 4: Verifying postgres_exporter metrics..."
for _i in $(seq 1 12); do
    PG_UP=$(kubectl exec -n "${NAMESPACE}" deploy/postgres -c exporter -- \
      wget -qO- http://localhost:9187/metrics 2>/dev/null \
      | grep '^pg_up ' | awk '{print $2}' || echo "0")
    [ "${PG_UP}" = "1" ] && break
    sleep 5
done
if [ "${PG_UP}" != "1" ]; then
    echo "WARNING: postgres_exporter not reporting pg_up=1 (got: ${PG_UP})"
fi
echo "  postgres_exporter: pg_up=${PG_UP}"
echo ""

echo "==> Step 5: Connection leaker running (~1 connection every 8s)."
echo "    Pool will saturate within ~2 minutes (10 leaked + system = 15 max)."
echo "    DatabaseConnectionPoolExhausted alert fires when active > 10."

# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}" || _rc=$?
fi

exit "${_rc:-0}"
