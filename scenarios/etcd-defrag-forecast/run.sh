#!/usr/bin/env bash
# etcd Defrag Forecast Demo -- Automated Runner
# Predictive etcd defragmentation: standalone etcd cluster with injected
# fragmentation, LLM investigates health + fragmentation ratio, workflow
# performs rolling defrag with manual approval gate.
#
# Prerequisites:
#   - OCP cluster with Kubernaut services
#   - DefragEtcd ActionType + defrag-etcd-v1 workflow registered
#   - StorageClass available for etcd PVCs (1Gi each)
#
# Usage: ./scenarios/etcd-defrag-forecast/run.sh [--auto-approve|--interactive]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="demo-etcd-defrag"

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
echo " etcd Defrag Forecast Demo"
echo "============================================="
echo ""

ensure_clean_slate "${NAMESPACE}"

# Step 1: Deploy etcd cluster
echo "==> Step 1: Deploying 3-member etcd cluster..."
MANIFEST_DIR=$(get_manifest_dir "${SCRIPT_DIR}")
kubectl apply -k "${MANIFEST_DIR}"

# Step 2: Wait for etcd to form a healthy cluster
echo "==> Step 2: Waiting for etcd StatefulSet to be ready..."
kubectl rollout status statefulset/etcd -n "${NAMESPACE}" --timeout=600s
echo "    etcd cluster ready."
kubectl get pods -n "${NAMESPACE}" -l app=etcd
echo ""

# Step 3: Verify cluster health
echo "==> Step 3: Verifying etcd cluster health..."
kubectl exec etcd-0 -n "${NAMESPACE}" -- \
    etcdctl --endpoints=http://localhost:2379 member list --write-out=table
echo ""

# Step 4: Wait for metrics to be scraped
echo "==> Step 4: Waiting for Prometheus to scrape etcd metrics (60s)..."
sleep 60

# Step 5: Inject fragmentation
echo "==> Step 5: Injecting etcd fragmentation..."
bash "${SCRIPT_DIR}/inject-fragmentation.sh"
echo ""

echo "==> Step 6: Waiting for EtcdHighFragmentationRatio alert."
echo "    The alert has a 2m 'for' clause. Expect ~3-4 min."

# Validate pipeline
if [ "${SKIP_VALIDATE}" != "true" ] && [ -f "${SCRIPT_DIR}/validate.sh" ]; then
    echo ""
    echo "==> Running validation pipeline..."
    bash "${SCRIPT_DIR}/validate.sh" "${APPROVE_MODE}" || _rc=$?
fi

exit "${_rc:-0}"
