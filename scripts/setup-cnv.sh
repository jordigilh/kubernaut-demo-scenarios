#!/usr/bin/env bash
# Install OpenShift Virtualization (CNV) on an OCP cluster.
#
# Idempotent — safe to run multiple times. Each step checks "already done?"
# before acting.
#
# Prerequisites:
#   - Authenticated to an OCP 4.14+ cluster (oc whoami)
#   - redhat-operators CatalogSource available
#
# Usage:
#   bash scripts/setup-cnv.sh
#   bash scripts/setup-cnv.sh --channel stable-4.21
#   bash scripts/setup-cnv.sh --skip-virtctl
set -euo pipefail

CHANNEL="${CNV_CHANNEL:-stable}"
SKIP_VIRTCTL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)    CHANNEL="$2"; shift 2 ;;
        --skip-virtctl) SKIP_VIRTCTL=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--channel CHANNEL] [--skip-virtctl]"
            echo ""
            echo "Options:"
            echo "  --channel CHANNEL   OLM subscription channel (default: stable)"
            echo "  --skip-virtctl      Skip virtctl CLI installation"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

TOTAL_START=$(date +%s)

echo "============================================="
echo " OpenShift Virtualization (CNV) Setup"
echo "============================================="
echo ""

# ── 0. Preflight ──────────────────────────────────────────────────────────────

echo "==> Phase 0: Preflight checks"

if ! oc whoami &>/dev/null; then
    echo "ERROR: Not authenticated to an OCP cluster. Run: oc login ..."
    exit 1
fi
echo "  Cluster: $(oc whoami --show-server)"
echo "  User:    $(oc whoami)"

if ! kubectl get catalogsource redhat-operators -n openshift-marketplace \
    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null | grep -q READY; then
    echo "ERROR: redhat-operators CatalogSource is not READY."
    exit 1
fi
echo "  CatalogSource: redhat-operators (READY)"

PKG_CHANNEL=$(kubectl get packagemanifest kubevirt-hyperconverged \
    -o jsonpath='{.status.channels[?(@.name=="'"${CHANNEL}"'")].name}' 2>/dev/null || true)
if [ -z "$PKG_CHANNEL" ]; then
    AVAILABLE=$(kubectl get packagemanifest kubevirt-hyperconverged \
        -o jsonpath='{range .status.channels[*]}{.name}{" "}{end}' 2>/dev/null || true)
    echo "WARNING: Channel '${CHANNEL}' not found for kubevirt-hyperconverged."
    echo "  Available channels: ${AVAILABLE:-none}"
    if [ -n "$AVAILABLE" ]; then
        CHANNEL=$(echo "$AVAILABLE" | awk '{print $1}')
        echo "  Falling back to: ${CHANNEL}"
    else
        echo "ERROR: No channels available. Is the CatalogSource up to date?"
        exit 1
    fi
fi
echo "  Package: kubevirt-hyperconverged (channel: ${CHANNEL})"
echo ""

# ── 1. CNV Operator ──────────────────────────────────────────────────────────

echo "==> Phase 1: CNV Operator"

CSV_NAME=$(kubectl get csv -n openshift-cnv -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep "^kubevirt-hyperconverged" | head -1)
if echo "$CSV_NAME" | grep -q "=Succeeded"; then
    echo "  CNV operator already installed: ${CSV_NAME%%=*}"
else
    echo "  Creating Namespace openshift-cnv..."
    kubectl create namespace openshift-cnv --dry-run=client -o yaml | kubectl apply -f -

    echo "  Creating OperatorGroup..."
    kubectl apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
YAML

    echo "  Creating Subscription (channel: ${CHANNEL})..."
    kubectl apply -f - <<YAML
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: ${CHANNEL}
  installPlanApproval: Automatic
YAML

    echo "  Waiting for HCO CSV to reach Succeeded (up to 10 min)..."
    _elapsed=0
    while true; do
        CSV_LINE=$(kubectl get csv -n openshift-cnv -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}{"\n"}{end}' 2>/dev/null \
            | grep "^kubevirt-hyperconverged" | head -1)
        PHASE="${CSV_LINE##*=}"
        if [ "$PHASE" = "Succeeded" ]; then
            echo "  CSV ready: ${CSV_LINE%%=*}"
            break
        fi
        if [ "$_elapsed" -ge 600 ]; then
            echo "ERROR: HCO CSV did not reach Succeeded after 10 min (current: ${PHASE:-Pending})"
            kubectl get csv -n openshift-cnv 2>/dev/null
            exit 1
        fi
        sleep 15
        _elapsed=$((_elapsed + 15))
        echo "  Waiting... (${_elapsed}s, phase: ${PHASE:-Pending})"
    done
fi
echo ""

# ── 2. HyperConverged CR ─────────────────────────────────────────────────────

echo "==> Phase 2: HyperConverged CR"

if kubectl get hyperconverged kubevirt-hyperconverged -n openshift-cnv &>/dev/null; then
    HC_AVAIL=$(kubectl get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
    echo "  HyperConverged CR already exists (Available: ${HC_AVAIL})"
else
    echo "  Creating HyperConverged CR..."
    kubectl apply -f - <<'YAML'
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  infra: {}
  workloads: {}
YAML

    echo "  Cleaning up failed/evicted pods that may cause node disk pressure..."
    kubectl get pods --all-namespaces --field-selector=status.phase==Failed --no-headers 2>/dev/null \
        | awk '{print $1, $2}' | while read ns pod; do
            kubectl delete pod "$pod" -n "$ns" --force --grace-period=0 &>/dev/null
        done

    echo "  Waiting for HyperConverged Available=True (up to 15 min)..."
    _elapsed=0
    while true; do
        HC_AVAIL=$(kubectl get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
        if [ "$HC_AVAIL" = "True" ]; then
            echo "  HyperConverged is Available."
            break
        fi
        # Auto-cleanup evicted virt-handler pods that block convergence
        kubectl get pods -n openshift-cnv -l kubevirt.io=virt-handler --field-selector=status.phase==Failed \
            --no-headers 2>/dev/null | awk '{print $1}' | while read pod; do
                kubectl delete pod "$pod" -n openshift-cnv --force --grace-period=0 &>/dev/null
            done
        if [ "$_elapsed" -ge 900 ]; then
            echo "ERROR: HyperConverged not Available after 15 min (current: ${HC_AVAIL})"
            kubectl get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
                -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>/dev/null
            exit 1
        fi
        sleep 15
        _elapsed=$((_elapsed + 15))
        echo "  Waiting... (${_elapsed}s, Available: ${HC_AVAIL})"
    done
fi
echo ""

# ── 3. KVM device verification ───────────────────────────────────────────────

echo "==> Phase 3: KVM device verification"

echo "  Waiting for virt-handler DaemonSet to be ready (up to 3 min)..."
_elapsed=0
while true; do
    DESIRED=$(kubectl get daemonset virt-handler -n openshift-cnv \
        -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    READY=$(kubectl get daemonset virt-handler -n openshift-cnv \
        -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    if [ "$DESIRED" != "0" ] && [ "$DESIRED" = "$READY" ]; then
        echo "  virt-handler DaemonSet ready: ${READY}/${DESIRED}"
        break
    fi
    if [ "$_elapsed" -ge 180 ]; then
        echo "ERROR: virt-handler DaemonSet not ready after 3 min (${READY}/${DESIRED})"
        exit 1
    fi
    sleep 10
    _elapsed=$((_elapsed + 10))
done

echo "  Checking KVM device on worker nodes..."
ALL_KVM=true
for node in $(kubectl get nodes -l node-role.kubernetes.io/worker -o name); do
    NODE_NAME=$(echo "$node" | cut -d/ -f2)
    KVM_COUNT=$(kubectl get "$node" -o jsonpath='{.status.allocatable.devices\.kubevirt\.io/kvm}' 2>/dev/null || echo "0")
    if [ "$KVM_COUNT" = "0" ] || [ -z "$KVM_COUNT" ]; then
        echo "  WARNING: ${NODE_NAME}: devices.kubevirt.io/kvm NOT available"
        ALL_KVM=false
    else
        echo "  ${NODE_NAME}: devices.kubevirt.io/kvm = ${KVM_COUNT}"
    fi
done

if [ "$ALL_KVM" = false ]; then
    echo ""
    echo "WARNING: KVM device not available on all workers."
    echo "  This cluster may not support nested virtualization."
    echo "  VMs will use software emulation (slow) or fail to start."
    echo "  For kcli/libvirt hosts, ensure nested virt is enabled:"
    echo "    modprobe -r kvm_intel && modprobe kvm_intel nested=1"
fi
echo ""

# ── 4. CDI verification ──────────────────────────────────────────────────────

echo "==> Phase 4: CDI (Containerized Data Importer)"

CDI_PHASE=$(kubectl get cdi -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [ "$CDI_PHASE" = "Deployed" ]; then
    echo "  CDI is Deployed."
else
    echo "  CDI phase: ${CDI_PHASE} (HyperConverged should deploy it automatically)"
    if [ "$CDI_PHASE" = "NotFound" ]; then
        echo "  WARNING: CDI CR not found. The HyperConverged CR may not have reconciled yet."
        echo "  Waiting up to 2 min..."
        _elapsed=0
        while true; do
            CDI_PHASE=$(kubectl get cdi -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
            if [ "$CDI_PHASE" = "Deployed" ]; then
                echo "  CDI is Deployed."
                break
            fi
            if [ "$_elapsed" -ge 120 ]; then
                echo "  WARNING: CDI still not Deployed after 2 min. Proceeding anyway."
                break
            fi
            sleep 10
            _elapsed=$((_elapsed + 10))
        done
    fi
fi
echo ""

# ── 5. virtctl CLI ────────────────────────────────────────────────────────────

if [ "$SKIP_VIRTCTL" = false ]; then
    echo "==> Phase 5: virtctl CLI"

    if command -v virtctl &>/dev/null; then
        echo "  virtctl already installed: $(virtctl version --client 2>/dev/null | head -1)"
    else
        echo "  Installing virtctl from ConsoleCLIDownload..."
        VIRTCTL_URL=$(kubectl get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged \
            -o jsonpath='{.spec.links[?(@.text=="Download virtctl for Linux for x86_64")].href}' 2>/dev/null || true)

        if [ -z "$VIRTCTL_URL" ]; then
            VIRTCTL_URL=$(kubectl get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged \
                -o jsonpath='{.spec.links[?(@.text=="Download virtctl for Mac for x86_64")].href}' 2>/dev/null || true)
        fi

        if [ -z "$VIRTCTL_URL" ]; then
            OS=$(uname -s | tr '[:upper:]' '[:lower:]')
            ARCH=$(uname -m)
            echo "  ConsoleCLIDownload URL not found. Trying direct download..."
            echo "  Skipping virtctl install — install manually:"
            echo "    oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged -o yaml"
        else
            echo "  Downloading from: ${VIRTCTL_URL}"
            TMPDIR=$(mktemp -d)
            if curl -sL "$VIRTCTL_URL" | tar xz -C "$TMPDIR" 2>/dev/null; then
                VIRTCTL_BIN=$(find "$TMPDIR" -name virtctl -type f | head -1)
                if [ -n "$VIRTCTL_BIN" ]; then
                    chmod +x "$VIRTCTL_BIN"
                    sudo mv "$VIRTCTL_BIN" /usr/local/bin/virtctl 2>/dev/null || \
                        mv "$VIRTCTL_BIN" "${HOME}/.local/bin/virtctl" 2>/dev/null || \
                        echo "  WARNING: Could not install virtctl to PATH. Binary at: ${VIRTCTL_BIN}"
                    echo "  virtctl installed: $(virtctl version --client 2>/dev/null | head -1)"
                fi
            else
                echo "  WARNING: Failed to download virtctl. Install manually."
            fi
            rm -rf "$TMPDIR"
        fi
    fi
    echo ""
fi

# ── 6. Final validation ──────────────────────────────────────────────────────

echo "==> Phase 6: Final validation"

PASS=true

_check() {
    local desc="$1" result="$2"
    if [ "$result" = "PASS" ]; then
        echo "  [PASS] $desc"
    else
        echo "  [FAIL] $desc ($result)"
        PASS=false
    fi
}

CSV_PHASE=$(kubectl get csv -n openshift-cnv -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep "^kubevirt-hyperconverged" | head -1 | cut -d= -f2)
_check "CNV operator CSV" "$([ "$CSV_PHASE" = "Succeeded" ] && echo PASS || echo "${CSV_PHASE:-NotFound}")"

HC_AVAIL=$(kubectl get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
_check "HyperConverged Available" "$([ "$HC_AVAIL" = "True" ] && echo PASS || echo "$HC_AVAIL")"

VH_READY=$(kubectl get daemonset virt-handler -n openshift-cnv \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
_check "virt-handler DaemonSet" "$([ "${VH_READY:-0}" -ge 1 ] && echo PASS || echo "0 ready")"

CDI_PHASE=$(kubectl get cdi -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
_check "CDI Deployed" "$([ "$CDI_PHASE" = "Deployed" ] && echo PASS || echo "$CDI_PHASE")"

WORKER_KVM=0
for node in $(kubectl get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null); do
    KVM=$(kubectl get "$node" -o jsonpath='{.status.allocatable.devices\.kubevirt\.io/kvm}' 2>/dev/null || echo "0")
    if [ -n "$KVM" ] && [ "$KVM" != "0" ]; then
        WORKER_KVM=$((WORKER_KVM + 1))
    fi
done
TOTAL_WORKERS=$(kubectl get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
_check "KVM on workers (${WORKER_KVM}/${TOTAL_WORKERS})" "$([ "$WORKER_KVM" -ge 1 ] && echo PASS || echo "no KVM")"

if command -v virtctl &>/dev/null; then
    _check "virtctl CLI" "PASS"
else
    echo "  [WARN] virtctl CLI not in PATH (optional)"
fi

TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - TOTAL_START))
total_mins=$((TOTAL_DURATION / 60))
total_secs=$((TOTAL_DURATION % 60))

echo ""
echo "============================================="
if [ "$PASS" = true ]; then
    echo " CNV setup complete! (${total_mins}m ${total_secs}s)"
else
    echo " CNV setup complete with issues (${total_mins}m ${total_secs}s)"
fi
echo "============================================="
echo ""
echo "Test with:"
echo "  kubectl get vmi -A"
echo "  virtctl create vm --name test-vm | kubectl apply -f -"
