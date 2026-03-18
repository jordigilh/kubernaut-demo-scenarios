# Scenario #312: Memory Limits GitOps via Ansible/AWX

> **Status: Unvalidated** -- This scenario has scaffolding but has not been tested end-to-end on any platform. See the [Scenario Catalog](../../docs/scenarios.md#unvalidated) for details.

## Overview

First demo scenario using the **Ansible execution engine** (AWX). A GitOps-managed
deployment has a container with an undersized memory limit (64Mi) that gets OOMKilled.
The LLM detects the `gitOpsTool` label, selects the GitOps-aware `IncreaseMemoryLimits`
workflow, and AWX executes an Ansible playbook that:

1. Reads the current memory limit from the deployment YAML in Git
2. Calculates a new limit (2x current)
3. Commits the updated limits to the Gitea repository
4. ArgoCD syncs the change to the cluster

**Signal**: `ContainerOOMKilling` -- OOMKill detected in namespace
**Root cause**: Memory limit too low (64Mi) for the workload
**Remediation**: `increase-memory-limits-gitops-v1` (Ansible engine via AWX)

## Signal Flow

```
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} for 0m
  -> ContainerOOMKilling alert
  -> Gateway -> SP -> AA (HAPI + LLM)
  -> LLM detects gitOpsTool label + OOMKill pattern
  -> Selects IncreaseMemoryLimits workflow (Ansible variant)
  -> RO -> WE (Ansible/AWX) runs playbook
  -> Git commit with updated limits -> ArgoCD sync
  -> EM verifies no more OOMKills
```

## Prerequisites

| Component | Requirement |
|-----------|-------------|
| Kind cluster | `overlays/kind/kind-cluster-config.yaml` |
| Kubernaut services | Gateway, SP, AA, RO, WE, EM deployed |
| LLM backend | Real LLM (not mock) via HAPI |
| Prometheus | With kube-state-metrics |
| AWX | Deployed via `scripts/awx-helper.sh` |
| Gitea + ArgoCD | Deployed via `scenarios/gitops/scripts/setup-gitea.sh` and `scenarios/gitops/scripts/setup-argocd.sh` |
| Workflow catalog | `increase-memory-limits-gitops-v1` registered in DataStorage |

## Automated Run

```bash
# Full run (setup + inject + validate)
./scenarios/memory-limits-gitops-ansible/run.sh

# Or step-by-step:
./scenarios/memory-limits-gitops-ansible/run.sh setup
./scenarios/memory-limits-gitops-ansible/run.sh inject
```

## Manual Step-by-Step

### 1. Deploy scenario resources

The deployment is created in Gitea and synced by ArgoCD. The `run.sh setup` phase handles:
- Creating the namespace, ArgoCD Application, and PrometheusRule via kustomize
- Pushing the deployment manifest to a Gitea repository
- Waiting for ArgoCD to sync

```bash
kubectl apply -k scenarios/memory-limits-gitops-ansible/manifests/
# Wait for ArgoCD to sync the deployment from Gitea
kubectl wait --for=condition=Available deployment/memory-consumer \
  -n demo-memory-gitops-ansible --timeout=180s
```

### 2. Verify healthy state

```bash
kubectl get pods -n demo-memory-gitops-ansible
```

### 3. Observe OOMKill

The `memory-consumer` container allocates ~8Mi every 2 seconds against a 64Mi limit.
It will be OOMKilled quickly.

```bash
kubectl get pods -n demo-memory-gitops-ansible -w
# Watch for OOMKilled -> CrashLoopBackOff
```

### 4. Wait for alert and pipeline

```bash
# ContainerOOMKilling alert fires immediately (for: 0m)
kubectl get rr,sp,aa,we,ea -n kubernaut-system -w
```

### 5. Verify remediation

```bash
# Memory limit should be increased in Git and synced by ArgoCD
kubectl get deployment/memory-consumer -n demo-memory-gitops-ansible \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
# Should show 128Mi (2x original 64Mi)

kubectl get pods -n demo-memory-gitops-ansible
# Pod should be Running without OOMKills
```

## Cleanup

```bash
kubectl delete namespace demo-memory-gitops-ansible
kubectl delete -f scenarios/memory-limits-gitops-ansible/manifests/argocd-application.yaml --ignore-not-found
```

## BDD Specification

```gherkin
Feature: Memory Limits GitOps via Ansible/AWX

  Scenario: OOMKilled container triggers Ansible playbook to increase limits via Git
    Given a Kind cluster with AWX, Gitea, and ArgoCD deployed
      And the "increase-memory-limits-gitops-v1" workflow is registered
      And a "memory-consumer" deployment is managed by ArgoCD from Gitea
      And the container has a memory limit of 64Mi

    When the container allocates memory beyond its 64Mi limit
      And Kubernetes OOMKills the container
      And the ContainerOOMKilling alert fires

    Then the LLM detects the gitOpsTool label and OOMKill pattern
      And selects the IncreaseMemoryLimits workflow (Ansible variant)
      And WE dispatches the Ansible playbook via AWX
      And the playbook reads the current limit from the Git repository
      And commits an updated deployment with increased memory limits
      And ArgoCD syncs the updated deployment to the cluster
      And EM verifies the container is Running without OOMKills
```

## Acceptance Criteria

- [ ] Memory consumer deployment is created via Gitea + ArgoCD
- [ ] Container gets OOMKilled due to 64Mi limit
- [ ] ContainerOOMKilling alert fires
- [ ] LLM detects gitOpsTool label and selects Ansible workflow
- [ ] AWX executes the playbook
- [ ] Memory limit is increased in the Git repository
- [ ] ArgoCD syncs the updated deployment
- [ ] Container runs without OOMKills after remediation
- [ ] EM confirms successful remediation
