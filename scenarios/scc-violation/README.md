# Scenario: Security Context Constraint (SCC) Violation

**Status**: PLANNED — not yet implemented

## Overview

Demonstrates Kubernaut diagnosing pods that fail to start due to OpenShift
Security Context Constraint (SCC) violations — typically
`CreateContainerConfigError` or `Forbidden` events referencing SCC denial.

## ITIL Mapping

| Level | Task |
|-------|------|
| L2 | Network security remediation — SCC policy adjustment |

## Signal

| Field | Value |
|-------|-------|
| Alert | `KubePodNotReady` with SCC-related events |
| Source | Prometheus AlertManager |
| Severity | medium |

## Investigation

KA investigates via the K8s dynamic client:

- Describe the affected pod to identify the SCC denial message
- List available SCCs and their constraints (`oc get scc`)
- Check the pod's SecurityContext (runAsUser, runAsGroup, fsGroup, capabilities)
- Review the ServiceAccount's SCC bindings
- Compare the pod's security requirements against the assigned SCC

## Remediation (customer-defined)

Possible workflow actions:
- Bind the ServiceAccount to a more permissive SCC (if policy allows)
- Patch the Deployment to adjust the SecurityContext to comply with the assigned SCC
- Escalate to platform team if SCC policy change is required (CAB approval)

## Prerequisites

- OpenShift cluster with SCC enforcement enabled (default)
- Prometheus with kube-state-metrics
- Customer-defined remediation workflow registered in DataStorage
