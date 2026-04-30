# Scenario: Operator Health Management (OLM)

**Status**: PLANNED — not yet implemented

## Overview

Demonstrates Kubernaut diagnosing and remediating OpenShift Operator Lifecycle Manager
(OLM) failures, including stuck Subscriptions, failed ClusterServiceVersions (CSVs),
and InstallPlan issues.

## ITIL Mapping

| Level | Task |
|-------|------|
| L2 | Availability management — Operator health |

## Signal

| Field | Value |
|-------|-------|
| Alert | `OLMOperatorInstallFailed` or `ClusterOperatorDegraded` |
| Source | Prometheus AlertManager (kube-state-metrics for OLM resources) |
| Severity | high |

## Investigation

KA investigates via the K8s dynamic client (Subscriptions, CSVs, InstallPlans,
CatalogSources are standard K8s CRDs managed by OLM):

- Describe the failing Subscription and its current CSV
- Check InstallPlan status and approval state
- Review CatalogSource health and connectivity
- Check operator pod logs for crash/error details
- Verify RBAC (ClusterRole, ClusterRoleBinding) for the operator's ServiceAccount

## Remediation (customer-defined)

Possible workflow actions:
- Retry failed InstallPlan approval
- Delete and recreate the Subscription to trigger re-install
- Roll back to previous CSV version
- Escalate to L3 if the operator requires a vendor patch

## Prerequisites

- OpenShift cluster with OLM enabled
- kube-state-metrics scraping OLM resources
- Customer-defined remediation workflow registered in DataStorage
