# Scenario: Image Pull Failure (ImagePullBackOff)

**Status**: IN PROGRESS — manifests, scripts, and remediation workflow YAML are in-repo; validate end-to-end on a cluster with the `refresh-pull-secret-job` bundle registered.

## Overview

Demonstrates Kubernaut diagnosing pods stuck in `ImagePullBackOff` when a Deployment references an `ImagePullSecret` that is deleted or invalid (simulated credential expiry). The demo deploys a workload that lists `registry-credentials` as an `imagePullSecret`, removes that Secret, and forces a pod recreate so the kubelet cannot satisfy the pull.

## ITIL Mapping

| Level | Task |
|-------|------|
| L1 | Known error resolution — registry credential expiry / ImagePullSecret remediation |

## Signal

| Field | Value |
|-------|-------|
| Alert | `ImagePullBackOffPersistent` (PrometheusRule in `demo-imagepull`) |
| Source | Prometheus / Alertmanager (kube-state-metrics) |
| Severity | high |

## Layout

| Path | Purpose |
|------|---------|
| `manifests/` | Namespace, docker-registry Secret, Deployment (`inventory-api`), PrometheusRule |
| `overlays/ocp/` | OCP user-agent patches (cluster-monitoring label, strip `release` on `PrometheusRule`) |
| `run.sh` | Deploy, baseline sleep, inject fault, optional validation |
| `inject-expired-credentials.sh` | Deletes `registry-credentials` and forces pod delete |
| `validate.sh` | Alert → RR → pipeline assertions; expects `refresh-pull-secret-job` bundle |
| `cleanup.sh` | Remove PrometheusRule, namespace, orchestrator tuning, pipeline CR cleanup, Alertmanager restart |
| `deploy/remediation-workflows/image-pull-failure/image-pull-failure.yaml` | `RefreshImagePullSecret` workflow (`refresh-pull-secret-v1`) RBAC + spec |

## Investigation (reference)

- Describe the pod and events for pull errors and missing-secret messages
- Confirm `imagePullSecrets` on the pod matches Secrets that exist in the namespace
- Distinguish bad credentials vs wrong image tag/registry

## Remediation (customer-defined)

- Refresh or recreate the `ImagePullSecret` from a trusted source, then roll pods / Deployment

## Prerequisites

- OpenShift or Kind cluster with Kubernaut services
- Prometheus with kube-state-metrics scraping `demo-imagepull` (OCP: namespace label `openshift.io/cluster-monitoring=true`)
- Customer-defined remediation workflow registered (bundle `refresh-pull-secret-job` aligned with `refresh-pull-secret-v1`)

## Quick run

```bash
./scenarios/image-pull-failure/run.sh --auto-approve
./scenarios/image-pull-failure/cleanup.sh
```
