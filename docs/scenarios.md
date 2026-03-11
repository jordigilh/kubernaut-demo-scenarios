[Home](../README.md) > Scenario Catalog

# Scenario Catalog

24 scenarios are available, organized by category. Each scenario deploys into its own namespace and can be run independently.

For the formal specification of scenario structure, deliverables, and authoring guidelines, see [BR-PLATFORM-002: Demo Scenario Specification](https://github.com/jordigilh/kubernaut/blob/main/docs/requirements/BR-PLATFORM-002-demo-scenario-specification.md).

## Dependencies

Some scenarios require additional components beyond the base platform. All dependencies are installed by [`setup-demo-cluster.sh`](setup.md#create-the-cluster) (use `--skip-infra` to skip optional ones, `--with-awx` for AWX). If a scenario's `run.sh` detects a missing dependency, it exits with a clear error message.

| Dependency | Scenarios | Notes |
|------------|-----------|-------|
| **kube-prometheus-stack** | All scenarios | Installed by `setup-demo-cluster.sh` |
| **metrics-server** | hpa-maxed, autoscale | Required for HPA CPU metrics |
| **cert-manager** | cert-failure, cert-failure-gitops | Certificate lifecycle management |
| **Linkerd** | mesh-routing-failure | Service mesh control plane |
| **blackbox-exporter** | slo-burn | HTTP probe metrics (probe_success) |
| **Helm CLI** | crashloop-helm | Helm-managed release rollback |
| **ArgoCD** | gitops-drift, cert-failure-gitops, memory-limits-gitops-ansible | GitOps delivery |
| **AWX** | memory-limits-gitops-ansible | Ansible automation platform |

Each scenario's `README.md` lists its specific prerequisites.

## Workload Health

| Scenario | Signal / Alert | Fault Injection | Remediation |
|----------|---------------|-----------------|-------------|
| [**crashloop**](../scenarios/crashloop/) | `KubePodCrashLooping` | Bad config causes restarts >3 in 10m | Rollback to last working revision |
| [**crashloop-helm**](../scenarios/crashloop-helm/) | `KubePodCrashLooping` | CrashLoop on Helm-managed release | `helm rollback` to previous revision |
| [**memory-leak**](../scenarios/memory-leak/) | `ContainerMemoryExhaustionPredicted` | Linear memory growth predicted to OOM | Graceful restart (rolling) |
| [**stuck-rollout**](../scenarios/stuck-rollout/) | `KubeDeploymentRolloutStuck` | Non-existent image tag | `kubectl rollout undo` |
| [**slo-burn**](../scenarios/slo-burn/) | `ErrorBudgetBurn` | Blackbox probe error rate >1.44% | Proactive rollback |
| [**memory-escalation**](../scenarios/memory-escalation/) | `ContainerMemoryHigh` | Memory usage exceeds threshold | Increase memory limits |
| [**memory-limits-gitops-ansible**](../scenarios/memory-limits-gitops-ansible/) | `OOMKilled` | OOMKill on GitOps-managed deployment | Ansible/AWX updates limits in Git, ArgoCD syncs |

## Autoscaling and Resources

| Scenario | Signal / Alert | Fault Injection | Remediation |
|----------|---------------|-----------------|-------------|
| [**hpa-maxed**](../scenarios/hpa-maxed/) | `KubeHpaMaxedOut` | CPU load drives HPA to ceiling | Patch `maxReplicas` +2 |
| [**pdb-deadlock**](../scenarios/pdb-deadlock/) | `KubePodDisruptionBudgetAtLimit` | PDB blocks all disruptions | Relax PDB `minAvailable` |
| [**autoscale**](../scenarios/autoscale/) | `KubePodSchedulingFailed` | Pods Pending (resource exhaustion) | Provision additional node |

## Infrastructure

| Scenario | Signal / Alert | Fault Injection | Remediation |
|----------|---------------|-----------------|-------------|
| [**pending-taint**](../scenarios/pending-taint/) | `KubePodNotScheduled` | NoSchedule taint on node | Remove taint |
| [**node-notready**](../scenarios/node-notready/) | `KubeNodeNotReady` | Node failure simulation | Cordon + drain node |
| [**orphaned-pvc-no-action**](../scenarios/orphaned-pvc-no-action/) | `KubePersistentVolumeClaimOrphaned` | Orphaned PVCs accumulate | No action (no workflow seeded) |
| [**statefulset-pvc-failure**](../scenarios/statefulset-pvc-failure/) | `KubeStatefulSetReplicasMismatch` | PVC binding failure | Fix StatefulSet PVC |

## Network and Service Mesh

| Scenario | Signal / Alert | Fault Injection | Remediation |
|----------|---------------|-----------------|-------------|
| [**network-policy-block**](../scenarios/network-policy-block/) | `KubePodCrashLooping` / `KubeDeploymentReplicasMismatch` | Deny-all NetworkPolicy | Fix NetworkPolicy rules |
| [**mesh-routing-failure**](../scenarios/mesh-routing-failure/) | `LinkerdHighErrorRate` / `LinkerdRequestsUnauthorized` | Restrictive AuthorizationPolicy | Fix AuthorizationPolicy |

## GitOps

| Scenario | Signal / Alert | Fault Injection | Remediation |
|----------|---------------|-----------------|-------------|
| [**gitops-drift**](../scenarios/gitops-drift/) | `KubePodCrashLooping` | Bad commit via ArgoCD | `git revert` offending commit |

## Certificates

| Scenario | Signal / Alert | Fault Injection | Remediation |
|----------|---------------|-----------------|-------------|
| [**cert-failure**](../scenarios/cert-failure/) | `CertManagerCertNotReady` | cert-manager Certificate NotReady | Fix Certificate resource |
| [**cert-failure-gitops**](../scenarios/cert-failure-gitops/) | `CertManagerCertNotReady` | Certificate NotReady (GitOps) | `git revert` cert config |

## Platform Behavior

| Scenario | Signal / Alert | Fault Injection | Behavior Tested |
|----------|---------------|-----------------|-----------------|
| [**duplicate-alert-suppression**](../scenarios/duplicate-alert-suppression/) | `KubePodCrashLooping` | Bad config (same as crashloop) | Deduplication suppresses duplicate RRs |
| [**resource-quota-exhaustion**](../scenarios/resource-quota-exhaustion/) | `KubeResourceQuotaExhausted` | Exhaust namespace ResourceQuota | Pipeline handles quota-blocked scenarios |
| [**concurrent-cross-namespace**](../scenarios/concurrent-cross-namespace/) | `KubePodCrashLooping` (x2) | Bad config in two namespaces | Concurrent pipelines with cross-namespace rego policy |
| [**resource-contention**](../scenarios/resource-contention/) | `OOMKilled` | External actor reverts remediation | Detects ineffective chain via spec drift, escalates to human review |
