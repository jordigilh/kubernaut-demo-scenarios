[Home](../README.md) > Scenario Catalog

# Scenario Catalog

37 scenarios are available, organized by category. Each scenario deploys into its own namespace and can be run independently.

For the formal specification of scenario structure, deliverables, and authoring guidelines, see [BR-PLATFORM-002: Demo Scenario Specification](https://github.com/jordigilh/kubernaut/blob/main/docs/requirements/BR-PLATFORM-002-demo-scenario-specification.md).

### Analysis Deep Dives

Two scenarios have detailed write-ups capturing real LLM decision-making observed during live cluster validation:

- [Multiple Remediation Paths](https://jordigilh.github.io/kubernaut-docs/use-cases/multi-path-remediation/) -- How the LLM chose an alternative fix for a GitOps-managed Certificate failure, and why both approaches are valid
- [Remediation History Feedback](https://jordigilh.github.io/kubernaut-docs/use-cases/remediation-history-feedback/) -- How the LLM refused to repeat a failed workflow for `resource-quota-exhaustion` after history revealed the prior attempt's failure, escalating to human review instead

## Dependencies

Some scenarios require additional components beyond the base platform. All dependencies are installed by [`setup-demo-cluster.sh`](setup.md#create-the-cluster) (use `--skip-infra` to skip optional ones, `--with-awx` for AWX). If a scenario's `run.sh` detects a missing dependency, it exits with a clear error message.

| Dependency | Scenarios | Notes |
|------------|-----------|-------|
| [**kube-prometheus-stack**](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) | All scenarios | Installed by `setup-demo-cluster.sh` |
| [**metrics-server**](https://github.com/kubernetes-sigs/metrics-server) | hpa-maxed, autoscale | Required for HPA CPU metrics |
| [**cert-manager**](https://cert-manager.io/docs/installation/) | cert-failure | Certificate lifecycle management |
| [**Istio**](https://istio.io/latest/docs/setup/getting-started/) | mesh-routing-failure | Service mesh control plane |
| [**blackbox-exporter**](https://github.com/prometheus/blackbox_exporter) | slo-burn | HTTP probe metrics (probe_success) |
| [**Helm CLI**](https://helm.sh/docs/intro/install/) | crashloop-helm | Helm-managed release rollback |
| [**ArgoCD**](https://argo-cd.readthedocs.io/en/stable/getting_started/) + [**Gitea**](https://gitea.io/) | gitops-drift, disk-pressure-emptydir | GitOps delivery + Git repository |
| [**AWX/AAP**](https://ansible.readthedocs.io/projects/awx-operator/en/latest/) | disk-pressure-emptydir | Ansible automation (AWX recommended; AAP supported with license) |
| **LVMS / expandable StorageClass** | pvc-capacity-forecast | StorageClass with `allowVolumeExpansion: true` |
| **postgres\_exporter** | db-connection-saturation | Deployed as sidecar (included in scenario manifests) |

Each scenario's `README.md` lists its specific prerequisites.

## Environment Legend

The **Environment** column indicates which platforms each scenario supports:

| Value | Meaning |
|-------|---------|
| **Both** | Runs on Kind and OCP |
| **OCP** | Requires OpenShift (AWX/AAP, privileged node access, or OCP-specific infrastructure) |
| **Kind** | Runs only on Kind (Linux and macOS) |
| **Kind (macOS)** | Runs only on Kind under macOS; Linux bare-metal Kind hits gateway payload limits due to high host memory |

## Approval Legend

The **Approval** column indicates whether the scenario enforces a manual approval gate before remediation executes. This makes the scenario deterministic regardless of LLM confidence.

| Value | Meaning |
|-------|---------|
| **Production** | `run.sh` patches the Rego policy so production environments *always* require manual approval (confidence-independent). Restored by `cleanup.sh`. |
| **Sensitive** | Approval is triggered by the default Rego rule `is_sensitive_resource` (Node, StatefulSet). No policy patch needed. |
| — | Auto-approved (staging or non-sensitive resource). |

## Workload Health

| Scenario | Signal / Alert | Fault Injection | Remediation | Approval | Environment |
|----------|---------------|-----------------|-------------|----------|-------------|
| [**crashloop**](../scenarios/crashloop/) | `KubePodCrashLooping` | Bad config causes restarts >3 in 10m | Rollback to last working revision | Production | Both |
| [**crashloop-helm**](../scenarios/crashloop-helm/) | `KubePodCrashLooping` | CrashLoop on Helm-managed release | `helm rollback` to previous revision | Production | Both |
| [**memory-leak**](../scenarios/memory-leak/) | `ContainerMemoryExhaustionPredicted` | Linear memory growth predicted to OOM | Graceful restart (rolling) | — | Both |
| [**stuck-rollout**](../scenarios/stuck-rollout/) | `KubeDeploymentRolloutStuck` | Non-existent image tag | `kubectl rollout undo` | Production | Both |
| [**slo-burn**](../scenarios/slo-burn/) | `ErrorBudgetBurn` | Blackbox probe error rate >1.44% | Proactive rollback | Production | Both |
| [**memory-escalation**](../scenarios/memory-escalation/) | `ContainerMemoryHigh` | Memory usage exceeds threshold | Increase memory limits | Production | Both |

## Autoscaling and Resources

| Scenario | Signal / Alert | Fault Injection | Remediation | Approval | Environment |
|----------|---------------|-----------------|-------------|----------|-------------|
| [**hpa-maxed**](../scenarios/hpa-maxed/) | `KubeHpaMaxedOut` | CPU load drives HPA to ceiling | Patch `maxReplicas` +2 | — | Both |
| [**pdb-deadlock**](../scenarios/pdb-deadlock/) | `KubePodDisruptionBudgetAtLimit` | PDB blocks all disruptions | Relax PDB `minAvailable` | Production | Both |
| [**autoscale**](../scenarios/autoscale/) | `KubePodSchedulingFailed` | Pods Pending (resource exhaustion) | Provision additional node | — | Kind (macOS) |

## Infrastructure

| Scenario | Signal / Alert | Fault Injection | Remediation | Approval | Environment |
|----------|---------------|-----------------|-------------|----------|-------------|
| [**pending-taint**](../scenarios/pending-taint/) | `KubePodNotScheduled` | NoSchedule taint on node | Remove taint | Sensitive | Both |
| [**node-notready**](../scenarios/node-notready/) | `KubeNodeNotReady` | Node failure simulation | Cordon + drain node | Sensitive | Kind |
| [**orphaned-pvc-no-action**](../scenarios/orphaned-pvc-no-action/) | `KubePersistentVolumeClaimOrphaned` | Orphaned PVCs accumulate | No action (no workflow seeded) | — | Both |
| [**statefulset-pvc-failure**](../scenarios/statefulset-pvc-failure/) | `KubeStatefulSetReplicasMismatch` | PVC binding failure | Fix StatefulSet PVC | Sensitive | Both |

## Network and Service Mesh

| Scenario | Signal / Alert | Fault Injection | Remediation | Approval | Environment |
|----------|---------------|-----------------|-------------|----------|-------------|
| [**network-policy-block**](../scenarios/network-policy-block/) | `KubePodCrashLooping` / `KubeDeploymentReplicasMismatch` | Deny-all NetworkPolicy | Fix NetworkPolicy rules | — | Both |
| [**mesh-routing-failure**](../scenarios/mesh-routing-failure/) | `IstioHighDenyRate` / `IstioRequestsUnauthorized` | Restrictive Istio AuthorizationPolicy | Fix AuthorizationPolicy | — | Both |

## GitOps

| Scenario | Signal / Alert | Fault Injection | Remediation | Approval | Environment |
|----------|---------------|-----------------|-------------|----------|-------------|
| [**gitops-drift**](../scenarios/gitops-drift/) | `KubePodCrashLooping` | Bad commit via ArgoCD | `git revert` offending commit | — | Both |
| [**disk-pressure-emptydir**](../scenarios/disk-pressure-emptydir/) | `PredictedDiskPressure` (proactive) | PostgreSQL on emptyDir fills disk | Ansible/AWX: pg\_dump, PVC migration commit to Git, ArgoCD sync, pg\_restore | Production | OCP |

## Certificates

| Scenario | Signal / Alert | Fault Injection | Remediation | Approval | Environment |
|----------|---------------|-----------------|-------------|----------|-------------|
| [**cert-failure**](../scenarios/cert-failure/) | `CertManagerCertNotReady` | cert-manager Certificate NotReady | Fix Certificate resource | — | Both |

## OCP Operations (v1.4)

New in v1.4. L1/L2 scenarios covering common OCP operational failures.

| Scenario | Signal / Alert | Fault Injection | Remediation | Approval | Environment |
|----------|---------------|-----------------|-------------|----------|-------------|
| [**image-pull-failure**](../scenarios/image-pull-failure/) | `ImagePullBackOffPersistent` | Delete ImagePullSecret | Recreate secret from template + restart Deployment | — | Both |
| [**route-misconfiguration**](../scenarios/route-misconfiguration/) | `HAProxyBackendDown` | Patch Route with wrong target Service | Fix Route `spec.to.name` to correct Service | — | OCP |
| [**build-failure**](../scenarios/build-failure/) | `BuildFailureRate` | Patch BuildConfig with bad Git URI | Restore known-good source URI + trigger rebuild | — | OCP |
| [**scc-violation**](../scenarios/scc-violation/) | `SCCViolationPodBlocked` | Add privileged SecurityContext under restricted-v2 | Revert SecurityContext to SCC-compliant config | — | OCP |
| [**operator-health**](../scenarios/operator-health/) | `OperatorCSVFailed` | Delete operator CSV | Recreate Subscription to trigger OLM re-install | — | OCP |
| [**rbac-failure**](../scenarios/rbac-failure/) | `RBACPolicyDenied` | Delete RoleBinding | Restore RoleBinding from template + restart affected Deployments | — | Both |

## L3 Problem Management (v1.4)

New in v1.4. These scenarios exercise deeper ITIL L3 capabilities: capacity planning, performance investigation, and cross-RR root-cause convergence. **OCP only.**

| Scenario | Signal / Alert | Fault Injection | Remediation | Approval | Environment |
|----------|---------------|-----------------|-------------|----------|-------------|
| [**pvc-capacity-forecast**](../scenarios/pvc-capacity-forecast/) | `PVRunwayShort` (proactive, `predict_linear`) | Data writer fills PVC at ~5 MB/min | Expand PVC (patch `spec.resources.requests.storage`) | — | OCP |
| [**db-connection-saturation**](../scenarios/db-connection-saturation/) | `DatabaseConnectionPoolExhausted` | Connection leaker exhausts `max_connections` | Graceful restart of offending workload | — | OCP |
| [**cascading-service-failure**](../scenarios/cascading-service-failure/) | `KubePodCrashLooping` (x2, different pods) | Postgres crash kills two dependent apps | Rollback postgres Deployment; RO dedup blocks second RR (`ResourceBusy`) | — | OCP |
| [**etcd-defrag-forecast**](../scenarios/etcd-defrag-forecast/) | `EtcdHighFragmentationRatio` | Write + delete 50k keys to fragment etcd | Rolling defrag via `kubectl exec` (one member at a time) | Production | OCP |

### L3 Scenario Details

- **pvc-capacity-forecast** -- PoC for Kubernaut as the action layer for RHACM capacity forecasting. Uses `predict_linear` on `kubelet_volume_stats_used_bytes` to fire before the PVC fills. Requires a StorageClass with `allowVolumeExpansion: true` (tested with `lvms-vg1`). New ActionType: `ExpandPersistentVolumeClaim`. New workflow: `expand-pvc-v1`.
- **db-connection-saturation** -- L3 performance investigation. The LLM must correlate `pg_stat_activity_count` with per-client breakdowns to identify the leaker among multiple workloads. Uses `postgres_exporter` as a superuser sidecar to ensure metrics survive saturation. Workflows: `increase-db-connections-v1` (PatchConfiguration) and `scale-replicas-v1` (ScaleReplicas).
- **cascading-service-failure** -- Tests the RO's post-AI-analysis dedup path. Two RRs with different signal fingerprints converge when the LLM identifies the same `remediationTarget` (`Deployment/postgres`). The RO's `AcquireLock` + `CheckResourceBusy` ensures one WFE runs; the second RR is blocked with `ResourceBusy`. Reuses existing rollback workflows.
- **etcd-defrag-forecast** -- Predictive etcd defragmentation. Standalone 3-member etcd cluster with injected fragmentation. LLM investigates member health, quorum, and fragmentation ratio before deciding to defrag. Rolling defrag via `kubectl exec` with health checks between members. Manual approval required. New ActionType: `DefragEtcd`. New workflow: `defrag-etcd-v1`. Designed for migration to real cluster etcd once validated.

## Safety and Adversarial (v1.4)

New in v1.4. These scenarios validate the shadow agent (alignment check) and LLM reasoning resilience against adversarial inputs.

| Scenario | Signal / Alert | Fault Injection | Behavior Tested | Approval | Environment |
|----------|---------------|-----------------|-----------------|----------|-------------|
| [**prompt-injection**](../scenarios/prompt-injection/) | `KubePodCrashLooping` | Authority-impersonation payload in ConfigMap | Shadow agent detects embedded SRE directive and blocks execution (`alignment_check_failed`) | — | Both |
| [**alert-misdirection**](../scenarios/alert-misdirection/) | `KubePodCrashLooping` | Misleading OOM narrative in alert description (actual root cause: bad command override) | LLM resists misleading alert description and selects rollback over memory increase | Production | Both |

## Platform Behavior

| Scenario | Signal / Alert | Fault Injection | Behavior Tested | Approval | Environment |
|----------|---------------|-----------------|-----------------|----------|-------------|
| [**duplicate-alert-suppression**](../scenarios/duplicate-alert-suppression/) | `KubePodCrashLooping` | Bad config (same as crashloop) | Deduplication suppresses duplicate RRs | — | Both |
| [**resource-quota-exhaustion**](../scenarios/resource-quota-exhaustion/) | `KubeResourceQuotaExhausted` | Exhaust namespace ResourceQuota | Pipeline handles quota-blocked scenarios ([analysis](https://jordigilh.github.io/kubernaut-docs/use-cases/remediation-history-feedback/)) | Production | Both |
| [**concurrent-cross-namespace**](../scenarios/concurrent-cross-namespace/) | `KubePodCrashLooping` (x2) | Bad config in two namespaces | Concurrent pipelines with cross-namespace rego policy | Production | Both |
| [**resource-contention**](../scenarios/resource-contention/) | `OOMKilled` | External actor reverts remediation | Detects ineffective chain via spec drift, escalates to human review | — | Both |


## L3 Advanced Diagnostics

The following scenarios address diagnostic capability gaps identified through coverage analysis. Scenario manifests and scripts exist and are included in the `run-overnight.sh` OCP validation matrix.

| Scenario | Signal / Alert | Fault Injection | Diagnostic Challenge | Environment |
|----------|---------------|-----------------|----------------------|-------------|
| [**cross-namespace-dependency**](../scenarios/cross-namespace-dependency/) | `KubePodCrashLooping` (apps in `demo-xns-app`) | Postgres crash in `demo-xns-infra` kills cross-namespace dependents | LLM must trace RCA across namespace boundaries to `Deployment/postgres` in a different namespace than the alert source | OCP |
| [**severity-misdirection**](../scenarios/severity-misdirection/) | `ContainerOOMKilling` (warning) + `KubePodCrashLooping` (critical) | Postgres OOM-killed (16Mi limit) causes api-gateway crash-loop | LLM must prioritize temporal causation over severity ranking (P1 symptom, P3 cause) | OCP |
| [**red-herring-noise**](../scenarios/red-herring-noise/) | `KubePodCrashLooping` (x2) + `ImagePullBackOffPersistent` (x1) | Postgres crash + unrelated canary with bad image tag | LLM must separate independent failures from the primary cascade; canary must not pollute RCA | OCP |

All three reuse existing rollback/restart workflows (no new ActionTypes or OCI bundles required).
