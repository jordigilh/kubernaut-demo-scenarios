# Scenario: Image Pull Failure (ImagePullBackOff)

## Overview

Demonstrates Kubernaut diagnosing pods stuck in `ImagePullBackOff` when the
`ImagePullSecret` required for cross-namespace pulls from the OCP internal
registry is deleted (simulated credential expiry). The deployment references
an image hosted in a private source namespace
(`demo-inventory-source/inventory-api:v1`); without the explicit
`registry-credentials` Secret the kubelet cannot authenticate and the pull
fails.

## ITIL Mapping

| Level | Task |
|-------|------|
| L1 | Known error resolution — registry credential expiry / ImagePullSecret remediation |

## Signal

| Field | Value |
|-------|-------|
| Alert | `ImagePullBackOffPersistent` (PrometheusRule in `demo-inventory`) |
| Source | Prometheus / Alertmanager (kube-state-metrics) |
| Severity | high |

## Layout

| Path | Purpose |
|------|---------|
| `manifests/` | Namespace, Deployment (`inventory-api`), PrometheusRule |
| `overlays/ocp/` | OCP patches (cluster-monitoring label, strip `release` on PrometheusRule) |
| `setup-registry.sh` | Creates private source namespace, imports image, generates dockerconfigjson secret and workflow template |
| `run.sh` | Setup registry, deploy, baseline sleep, inject fault, optional validation |
| `inject-expired-credentials.sh` | Deletes `registry-credentials` and forces pod recreate (single fault) |
| `validate.sh` | Alert -> RR -> pipeline assertions; expects `refresh-pull-secret-job` bundle |
| `cleanup.sh` | Remove demo + source namespaces, template secret, pipeline CRs |

## How It Works

1. `setup-registry.sh` creates namespace `demo-inventory-source` and imports
   `registry.k8s.io/e2e-test-images/busybox:1.29-2` as an ImageStream.
   A ServiceAccount token is used to build a `dockerconfigjson` Secret
   (`registry-credentials`) that grants cross-namespace pull access.
   A copy is stored as `registry-credentials-template` in `kubernaut-workflows`
   for the remediation workflow.

2. The `inventory-api` Deployment pulls from the internal registry at
   `image-registry.openshift-image-registry.svc:5000/demo-inventory-source/inventory-api:v1`
   using `imagePullSecrets: [{name: registry-credentials}]`.

3. Fault injection deletes `registry-credentials` and scales to force a new pod.
   The pod cannot authenticate to the internal registry and enters `ImagePullBackOff`.

4. The `refresh-pull-secret-v1` workflow recreates the secret from the template
   in `kubernaut-workflows`, restarts the Deployment, and the pod recovers.

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Cluster | OpenShift with internal image registry enabled |
| Monitoring | Prometheus with kube-state-metrics scraping `demo-inventory` (`openshift.io/cluster-monitoring=true`) |
| Workflow catalog | `refresh-pull-secret-v1` registered (bundle `refresh-pull-secret-job`) |
| CLI | `oc` CLI available (used by `setup-registry.sh` for `import-image` and `create token`) |

## Quick run

```bash
./scenarios/image-pull-failure/run.sh --auto-approve
./scenarios/image-pull-failure/cleanup.sh
```
