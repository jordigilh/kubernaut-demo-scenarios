# Scenario: Image Pull Failure (ImagePullBackOff)

**Status**: PLANNED — not yet implemented

## Overview

Demonstrates Kubernaut diagnosing pods stuck in `ImagePullBackOff` or
`ErrImagePull` status due to registry authentication failures, missing images,
or registry rate limiting.

## ITIL Mapping

| Level | Task |
|-------|------|
| L1 | Known error resolution — Image pull remediation |

## Signal

| Field | Value |
|-------|-------|
| Alert | `KubePodNotReady` or `KubeContainerWaiting` with reason `ImagePullBackOff` |
| Source | Prometheus AlertManager |
| Severity | high |

## Investigation

KA investigates via the K8s dynamic client:

- Describe the affected pod to identify the ImagePullBackOff reason
- Review pod events for specific pull error messages (401 Unauthorized, 404 Not Found, rate limit)
- Check the image reference (registry, repository, tag/digest)
- Verify ImagePullSecrets referenced by the pod's ServiceAccount
- Check if other pods in the namespace successfully pull from the same registry

## Remediation (customer-defined)

Possible workflow actions:
- Refresh expired registry credentials (ImagePullSecret rotation)
- Correct image reference (tag, digest, registry URL)
- Switch to a mirror registry if the primary is rate-limited
- Escalate to L2 if the image genuinely does not exist

## Prerequisites

- OpenShift cluster with Kubernaut services deployed
- Prometheus with kube-state-metrics
- Customer-defined remediation workflow registered in DataStorage
