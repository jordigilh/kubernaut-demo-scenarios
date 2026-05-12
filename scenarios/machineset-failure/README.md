# Scenario: MachineSet / Machine Failure

**Status**: PLANNED — not yet implemented

## Overview

Demonstrates Kubernaut diagnosing OpenShift Machine API failures — Machines
stuck in `Provisioning` or `Failed` phase, MachineHealthCheck triggering
node drain, or MachineSet unable to scale to desired replicas.

## ITIL Mapping

| Level | Task |
|-------|------|
| L2 | Availability management — Infrastructure node lifecycle |

## Signal

| Field | Value |
|-------|-------|
| Alert | `MachineNotReady` or `MachineSetReplicasMismatch` |
| Source | Prometheus AlertManager |
| Severity | critical |

## Investigation

KA investigates via the K8s dynamic client:

- Describe the affected Machine and its phase/status conditions
- Check the MachineSet desired vs current replica count
- Review Machine events for provisioning errors (cloud API failures, quota exhaustion)
- Check MachineHealthCheck status and remediation history
- Verify cloud provider credentials and quota availability
- Review node drain events if MachineHealthCheck triggered remediation

## Remediation (customer-defined)

Possible workflow actions:
- Delete the stuck Machine to trigger MachineSet re-provisioning
- Scale up MachineSet to compensate for lost capacity
- Escalate to cloud operations if the failure is quota or infrastructure related

## Prerequisites

- OpenShift cluster with Machine API (IPI or assisted install)
- Prometheus monitoring Machine API resources
- Customer-defined remediation workflow registered in DataStorage
