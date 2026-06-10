#!/usr/bin/env bash
# Scenario registry: maps scenario directory names to Kubernetes namespace names.
# Source this file from automation scripts that need to resolve namespaces.
#
# Usage:
#   source scripts/scenario-registry.sh
#   ns="${SCENARIO_NS[crashloop]}"   # -> "demo-checkout"

declare -A SCENARIO_NS=(
  # ── v1.5 GA validation scenarios ──────────────────────────────────────────
  [crashloop]="demo-checkout"
  [crashloop-helm]="demo-storefront"
  [memory-leak]="demo-telemetry"
  [etcd-defrag-forecast]="demo-datastore"
  [operator-oomkill-informer]="demo-controllers"
  [pdb-deadlock]="demo-payments"
  [pending-taint]="demo-scheduler"
  [stuck-rollout]="demo-shipping"
  [hpa-maxed]="demo-gateway"
  [network-policy-block]="demo-frontend"
  [statefulset-pvc-failure]="demo-keystore"
  [resource-quota-exhaustion]="demo-platform"
  [orphaned-pvc-no-action]="demo-batch"
  [cert-failure]="demo-portal"
  [slo-burn]="demo-api"
  [disk-pressure-emptydir]="demo-warehouse"
  [concurrent-cross-namespace]="demo-team-alpha demo-team-beta"
  [duplicate-alert-suppression]="demo-ingress"
  [resource-contention]="demo-analytics"

  # ── Remaining scenarios ───────────────────────────────────────────────────
  [mesh-routing-failure]="demo-mesh"
  [rbac-failure]="demo-monitoring"
  [scc-violation]="demo-agents"
  [gitops-drift]="demo-webui"
  [route-misconfiguration]="demo-store"
  [db-connection-saturation]="demo-orders"
  [autoscale]="demo-loadtest"
  [image-pull-failure]="demo-inventory"
  [memory-escalation]="demo-ml-pipeline"
  [node-notready]="demo-compute"
  [build-failure]="demo-ci"
  [pvc-capacity-forecast]="demo-archive"
  [operator-health]="demo-operator"
  [cross-namespace-dependency]="demo-xns-infra demo-xns-app"

  # ── Misdirection / adversarial scenarios (namespace names kept intentional) ─
  [alert-misdirection]="demo-backend"
  [severity-misdirection]="demo-services"
  [red-herring-noise]="demo-microservices"
  [prompt-injection]="demo-workers"
  [cascading-service-failure]="demo-fulfillment"
)

# Reverse map: namespace -> scenario directory name.
# For multi-namespace scenarios, each namespace maps to the same scenario.
declare -A NS_TO_SCENARIO=()
for _scenario in "${!SCENARIO_NS[@]}"; do
  for _ns in ${SCENARIO_NS[$_scenario]}; do
    NS_TO_SCENARIO[$_ns]="$_scenario"
  done
done
unset _scenario _ns
