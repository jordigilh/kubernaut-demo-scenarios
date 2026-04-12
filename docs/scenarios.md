[Home](../README.md) > Scenario Catalog

# Scenario Catalog

23 scenarios are available, organized by category. Each scenario deploys into its own namespace and can be run independently.

For the formal specification of scenario structure, deliverables, and authoring guidelines, see [BR-PLATFORM-002: Demo Scenario Specification](https://github.com/jordigilh/kubernaut/blob/main/docs/requirements/BR-PLATFORM-002-demo-scenario-specification.md).

### Analysis Deep Dives

Two scenarios have detailed write-ups capturing real LLM decision-making observed during live cluster validation:

- [Multiple Remediation Paths](https://jordigilh.github.io/kubernaut-docs/use-cases/multi-path-remediation/) -- How the LLM chose an alternative fix for a GitOps-managed Certificate failure (`cert-failure-gitops`), and why both approaches are valid
- [Remediation History Feedback](https://jordigilh.github.io/kubernaut-docs/use-cases/remediation-history-feedback/) -- How the LLM refused to repeat a failed workflow for `resource-quota-exhaustion` after history revealed the prior attempt's failure, escalating to human review instead

## Dependencies

Some scenarios require additional components beyond the base platform. All dependencies are installed by [`setup-demo-cluster.sh`](setup.md#create-the-cluster) (use `--skip-infra` to skip optional ones, `--with-awx` for AWX). If a scenario's `run.sh` detects a missing dependency, it exits with a clear error message.

| Dependency | Scenarios | Notes |
|------------|-----------|-------|
| [**kube-prometheus-stack**](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) | All scenarios | Installed by `setup-demo-cluster.sh` |
| [**metrics-server**](https://github.com/kubernetes-sigs/metrics-server) | hpa-maxed, autoscale | Required for HPA CPU metrics |
| [**cert-manager**](https://cert-manager.io/docs/installation/) | cert-failure, cert-failure-gitops | Certificate lifecycle management |
| [**Istio**](https://istio.io/latest/docs/setup/getting-started/) | mesh-routing-failure | Service mesh control plane |
| [**blackbox-exporter**](https://github.com/prometheus/blackbox_exporter) | slo-burn | HTTP probe metrics (probe_success) |
| [**Helm CLI**](https://helm.sh/docs/intro/install/) | crashloop-helm | Helm-managed release rollback |
| [**ArgoCD**](https://argo-cd.readthedocs.io/en/stable/getting_started/) + [**Gitea**](https://gitea.io/) | gitops-drift, cert-failure-gitops, disk-pressure-emptydir | GitOps delivery + Git repository |
| [**AWX/AAP**](https://ansible.readthedocs.io/projects/awx-operator/en/latest/) | disk-pressure-emptydir | Ansible automation (AWX recommended; AAP supported with license) |

Each scenario's `README.md` lists its specific prerequisites.

## Environment Legend

The **Environment** column indicates which platforms each scenario supports:

| Value | Meaning |
|-------|---------|
| **Both** | Runs on Kind and OCP |
| **OCP** | Requires OpenShift (AWX/AAP, privileged node access, or OCP-specific infrastructure) |
| **Kind** | Runs only on Kind (Linux and macOS) |
| **Kind (macOS)** | Runs only on Kind under macOS; Linux bare-metal Kind hits gateway payload limits due to high host memory |

## Workload Health

| Scenario | Signal / Alert | Fault Injection | Remediation | Environment |
|----------|---------------|-----------------|-------------|-------------|
| [**crashloop**](../scenarios/crashloop/) | `KubePodCrashLooping` | Bad config causes restarts >3 in 10m | Rollback to last working revision | Both |
| [**crashloop-helm**](../scenarios/crashloop-helm/) | `KubePodCrashLooping` | CrashLoop on Helm-managed release | `helm rollback` to previous revision | Both |
| [**memory-leak**](../scenarios/memory-leak/) | `ContainerMemoryExhaustionPredicted` | Linear memory growth predicted to OOM | Graceful restart (rolling) | Both |
| [**stuck-rollout**](../scenarios/stuck-rollout/) | `KubeDeploymentRolloutStuck` | Non-existent image tag | `kubectl rollout undo` | Both |
| [**slo-burn**](../scenarios/slo-burn/) | `ErrorBudgetBurn` | Blackbox probe error rate >1.44% | Proactive rollback | Both |
| [**memory-escalation**](../scenarios/memory-escalation/) | `ContainerMemoryHigh` | Memory usage exceeds threshold | Increase memory limits | Both |

## Autoscaling and Resources

| Scenario | Signal / Alert | Fault Injection | Remediation | Environment |
|----------|---------------|-----------------|-------------|-------------|
| [**hpa-maxed**](../scenarios/hpa-maxed/) | `KubeHpaMaxedOut` | CPU load drives HPA to ceiling | Patch `maxReplicas` +2 | Both |
| [**pdb-deadlock**](../scenarios/pdb-deadlock/) | `KubePodDisruptionBudgetAtLimit` | PDB blocks all disruptions | Relax PDB `minAvailable` | Both |
| [**autoscale**](../scenarios/autoscale/) | `KubePodSchedulingFailed` | Pods Pending (resource exhaustion) | Provision additional node | Kind (macOS) |

## Infrastructure

| Scenario | Signal / Alert | Fault Injection | Remediation | Environment |
|----------|---------------|-----------------|-------------|-------------|
| [**pending-taint**](../scenarios/pending-taint/) | `KubePodNotScheduled` | NoSchedule taint on node | Remove taint | Both |
| [**node-notready**](../scenarios/node-notready/) | `KubeNodeNotReady` | Node failure simulation | Cordon + drain node | Kind |
| [**orphaned-pvc-no-action**](../scenarios/orphaned-pvc-no-action/) | `KubePersistentVolumeClaimOrphaned` | Orphaned PVCs accumulate | No action (no workflow seeded) | Both |
| [**statefulset-pvc-failure**](../scenarios/statefulset-pvc-failure/) | `KubeStatefulSetReplicasMismatch` | PVC binding failure | Fix StatefulSet PVC | Both |

## Network and Service Mesh

| Scenario | Signal / Alert | Fault Injection | Remediation | Environment |
|----------|---------------|-----------------|-------------|-------------|
| [**network-policy-block**](../scenarios/network-policy-block/) | `KubePodCrashLooping` / `KubeDeploymentReplicasMismatch` | Deny-all NetworkPolicy | Fix NetworkPolicy rules | Both |
| [**mesh-routing-failure**](../scenarios/mesh-routing-failure/) | `IstioHighDenyRate` / `IstioRequestsUnauthorized` | Restrictive Istio AuthorizationPolicy | Fix AuthorizationPolicy | Both |

## GitOps

| Scenario | Signal / Alert | Fault Injection | Remediation | Environment |
|----------|---------------|-----------------|-------------|-------------|
| [**gitops-drift**](../scenarios/gitops-drift/) | `KubePodCrashLooping` | Bad commit via ArgoCD | `git revert` offending commit | Both |
| [**cert-failure-gitops**](../scenarios/cert-failure-gitops/) | `CertManagerCertNotReady` | Certificate NotReady (GitOps) | `git revert` cert config ([analysis](https://jordigilh.github.io/kubernaut-docs/use-cases/multi-path-remediation/)) | Both |
| [**disk-pressure-emptydir**](../scenarios/disk-pressure-emptydir/) | `PredictedDiskPressure` (proactive) | PostgreSQL on emptyDir fills disk | Ansible/AWX: pg\_dump, PVC migration commit to Git, ArgoCD sync, pg\_restore | OCP |

## Certificates

| Scenario | Signal / Alert | Fault Injection | Remediation | Environment |
|----------|---------------|-----------------|-------------|-------------|
| [**cert-failure**](../scenarios/cert-failure/) | `CertManagerCertNotReady` | cert-manager Certificate NotReady | Fix Certificate resource | Both |

## Platform Behavior

| Scenario | Signal / Alert | Fault Injection | Behavior Tested | Environment |
|----------|---------------|-----------------|-----------------|-------------|
| [**duplicate-alert-suppression**](../scenarios/duplicate-alert-suppression/) | `KubePodCrashLooping` | Bad config (same as crashloop) | Deduplication suppresses duplicate RRs | Both |
| [**resource-quota-exhaustion**](../scenarios/resource-quota-exhaustion/) | `KubeResourceQuotaExhausted` | Exhaust namespace ResourceQuota | Pipeline handles quota-blocked scenarios ([analysis](https://jordigilh.github.io/kubernaut-docs/use-cases/remediation-history-feedback/)) | Both |
| [**concurrent-cross-namespace**](../scenarios/concurrent-cross-namespace/) | `KubePodCrashLooping` (x2) | Bad config in two namespaces | Concurrent pipelines with cross-namespace rego policy | Both |
| [**resource-contention**](../scenarios/resource-contention/) | `OOMKilled` | External actor reverts remediation | Detects ineffective chain via spec drift, escalates to human review | Both |

