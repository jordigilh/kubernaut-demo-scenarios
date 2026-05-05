#!/usr/bin/env bash
# Shared scenario-dir:image-name mappings for demo workflow scripts.
# Sourced by build-demo-workflows.sh and seed-workflows.sh.
#
# Format: "scenario-directory:image-name"
# The exec image is <registry>/<image-name>:<version>
# The schema image is <registry>/<image-name>-schema:<version>

WORKFLOWS=(
    "gitops-drift:git-revert-job"
    "autoscale:provision-node-job"
    "slo-burn:proactive-rollback-job"
    "memory-leak:graceful-restart-job"
    "memory-escalation:increase-memory-limits-job"
    "crashloop:crashloop-rollback-job"
    "hpa-maxed:patch-hpa-job"
    "pdb-deadlock:relax-pdb-job"
    "pending-taint:remove-taint-job"
    "orphaned-pvc-no-action:cleanup-pvc-job"
    "node-notready:cordon-drain-job"
    "stuck-rollout:rollback-deployment-job"
    "cert-failure:fix-certificate-job"
    "crashloop-helm:helm-rollback-job"
    "mesh-routing-failure:fix-authz-policy-job"
    "statefulset-pvc-failure:fix-statefulset-pvc-job"
    "network-policy-block:fix-network-policy-job"
    "resource-contention:increase-memory-limits-job"
    "disk-pressure-emptydir:migrate-emptydir-to-pvc-gitops"
    "concurrent-cross-namespace:hotfix-config-job"
    "pvc-capacity-forecast:expand-pvc-job"
    "image-pull-failure:refresh-pull-secret-job"
    "route-misconfiguration:fix-route-target-job"
    "build-failure:fix-build-source-job"
    "scc-violation:fix-security-context-job"
    "operator-health:restore-operator-csv-job"
    "rbac-failure:restore-rolebinding-job"
    "etcd-defrag-forecast:defrag-etcd-job"
)
