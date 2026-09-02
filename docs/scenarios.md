[Home](../README.md) > Scenario Catalog

# Scenario Catalog

38 scenarios are available, grouped by ITIL support tier. Each scenario deploys into its own namespace and can be run independently.

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

## Support Tier Legend

Every scenario is grouped by the ITIL support tier its remediation complexity represents:

| Tier | Meaning |
|------|---------|
| **L1** | Known-error, single deterministic fix. No real investigation required. |
| **L2** | Requires domain-specific technical knowledge (networking, mesh, security policy, GitOps, capacity), but still one clear root cause. |
| **L3** | Problem management: deep RCA, cross-system correlation, capacity/performance forecasting, or resistance to adversarial/noisy signals. |

## Deployment Mode Legend

All 38 scenarios run single-cluster (`run.sh` → `local/run.sh`) by default -- this is unaffected by fleet mode, which is purely additive. The three columns below each table describe *where* a scenario can run:

| Column | Meaning |
|--------|---------|
| **Kind** | Validated on a local Kind cluster (Linux and macOS, unless noted). |
| **Fleet** | Validated in fleet mode: a hub cluster runs the Kubernaut control plane, a separate spoke cluster runs the demo workload. Requires `--fleet` plus `HUB_KUBECONFIG`/`SPOKE_KUBECONFIG` (hard error if either is missing). ✅ fully verified end-to-end · ⚠️ fleet code exists but the scenario's defining signal/narrative doesn't fully come through (see linked issue) · ❌ no fleet split written · — not applicable. Every ✅/⚠️ scenario except `resource-contention` ([#423](https://github.com/jordigilh/kubernaut-demo-scenarios/issues/423)) and `gitops-drift` ([kubernaut#2326](https://github.com/jordigilh/kubernaut/issues/2326)) now drives the **full remediation pipeline** on the hub (`--auto-approve`/`--interactive`, `--alert-only` stops early) via the shared `fleet_drive_pipeline` helper -- live-verified end-to-end for `crashloop`; the rest share the identical mechanism, unverified individually. Those two remain alert-only for scenario-specific reasons (see their own `fleet/hub.sh`). |
| **OCP** | Validated on real OpenShift. ⚠️ = manifests/overlay exist but no golden transcript or overnight-validation record exists yet -- never actually run. |

## Approval Legend

The **Approval** column indicates whether the scenario enforces a manual approval gate before remediation executes. This makes the scenario deterministic regardless of LLM confidence.

| Value | Meaning |
|-------|---------|
| **Production** | `run.sh` patches the Rego policy so production environments *always* require manual approval (confidence-independent). Restored by `cleanup.sh`. |
| **Sensitive** | Approval is triggered by the default Rego rule `is_sensitive_resource` (Node, StatefulSet). No policy patch needed. |
| — | Auto-approved (staging or non-sensitive resource). |

## L1 -- Event/Incident

Known-error, single deterministic fix.

| Scenario | Kind | Fleet | OCP | Approval | What it covers |
|----------|------|-------|-----|----------|-----------------|
| [**crashloop**](../scenarios/crashloop/) | ✅ | ✅ | ✅ | Production | Bad config causes restarts >3 in 10m → rollback to last working revision |
| [**crashloop-helm**](../scenarios/crashloop-helm/) | ✅ | ✅ | ✅ | Production | CrashLoop on a Helm-managed release → `helm rollback` to previous revision |
| [**stuck-rollout**](../scenarios/stuck-rollout/) | ✅ | ✅ | ✅ | Production | Non-existent image tag stalls the rollout → `kubectl rollout undo` |
| [**memory-leak**](../scenarios/memory-leak/) | ✅ | ✅ | ✅ | — | Linear memory growth predicted to OOM → graceful rolling restart |
| [**hpa-maxed**](../scenarios/hpa-maxed/) | ✅ | ✅ | ✅ | — | CPU load drives HPA to its ceiling → patch `maxReplicas` +2 |
| [**pending-taint**](../scenarios/pending-taint/) | ✅ | ❌ | ✅ | Sensitive | `NoSchedule` taint blocks pods → remove the taint |
| [**orphaned-pvc-no-action**](../scenarios/orphaned-pvc-no-action/) | ✅ | ✅ | ✅ | — | Orphaned PVCs accumulate → deliberately no workflow seeded (tests non-action) |
| [**image-pull-failure**](../scenarios/image-pull-failure/) | ✅ | ❌ | ✅ | — | Deleted ImagePullSecret → recreate from template + restart Deployment |
| [**rbac-failure**](../scenarios/rbac-failure/) | ✅ | ✅ | ✅ | — | Deleted RoleBinding → restore from template + restart affected Deployments |
| [**duplicate-alert-suppression**](../scenarios/duplicate-alert-suppression/) | ✅ | ✅ | ✅ | — | Same bad config as crashloop → tests RR deduplication, not a new fix |
| [**vm-boot-failure**](../scenarios/vm-boot-failure/) | ❌ | ❌ | ⚠️ | Production | Bad DataVolume source URL → VM stuck Provisioning → fix the DV source (`KubeVirtVMProvisioningStuck`). Manifests/overlay exist but this has never actually been run: absent from `run-overnight.sh`'s matrix, no golden transcript. Pending real OCP+CNV validation. |

## L2 -- Technical/Second-line

Domain-specific technical knowledge required, still one clear root cause.

| Scenario | Kind | Fleet | OCP | Approval | What it covers |
|----------|------|-------|-----|----------|-----------------|
| [**pdb-deadlock**](../scenarios/pdb-deadlock/) | ✅ | ❌ | ✅ | Production | PDB blocks all disruptions → relax `minAvailable` |
| [**autoscale**](../scenarios/autoscale/) | ✅ (macOS) | ❌ | ❌ | — | Pods Pending on resource exhaustion → provision an additional node |
| [**node-notready**](../scenarios/node-notready/) | ✅ | ❌ | ❌ | Sensitive | Simulated node failure → cordon + drain |
| [**statefulset-pvc-failure**](../scenarios/statefulset-pvc-failure/) | ✅ | ✅ | ✅ | Sensitive | PVC binding failure on a StatefulSet → fix the PVC |
| [**network-policy-block**](../scenarios/network-policy-block/) | ✅ | ✅ | ✅ | — | Deny-all NetworkPolicy → fix policy rules |
| [**mesh-routing-failure**](../scenarios/mesh-routing-failure/) | ✅ | ✅ | ✅ | — | Restrictive Istio AuthorizationPolicy → fix the policy |
| [**gitops-drift**](../scenarios/gitops-drift/) | ✅ | ✅ | ✅ | — | Bad commit synced via ArgoCD → `git revert` the offending commit |
| [**cert-failure**](../scenarios/cert-failure/) | ✅ | ✅ | ✅ | — | cert-manager Certificate stuck NotReady → fix the Certificate resource |
| [**route-misconfiguration**](../scenarios/route-misconfiguration/) | ❌ | ❌ | ✅ | — | Route patched to the wrong Service → fix `spec.to.name` |
| [**build-failure**](../scenarios/build-failure/) | ❌ | ❌ | ✅ | — | BuildConfig patched with a bad Git URI → restore source + trigger rebuild |
| [**scc-violation**](../scenarios/scc-violation/) | ❌ | ✅ | ✅ | — | Privileged SecurityContext under restricted-v2 → revert to SCC-compliant config |
| [**operator-health**](../scenarios/operator-health/) | ❌ | ❌ | ✅ | — | Deleted operator CSV → recreate Subscription to trigger OLM re-install |
| [**slo-burn**](../scenarios/slo-burn/) | ✅ | ✅ | ✅ | Production | Blackbox probe error rate >1.44% → proactive rollback before SLO burns |
| [**resource-quota-exhaustion**](../scenarios/resource-quota-exhaustion/) | ✅ | ✅ | ✅ | Production | Namespace ResourceQuota exhausted → pipeline handles the quota-blocked case ([analysis](https://jordigilh.github.io/kubernaut-docs/use-cases/remediation-history-feedback/)) |
| [**concurrent-cross-namespace**](../scenarios/concurrent-cross-namespace/) | ✅ | ✅ | ✅ | Production | Bad config in two namespaces at once → concurrent pipelines, cross-namespace rego |

## L3 -- Problem Management

Deep RCA, cross-system correlation, capacity/performance forecasting, or resistance to adversarial/noisy signals.

| Scenario | Kind | Fleet | OCP | Approval | What it covers |
|----------|------|-------|-----|----------|-----------------|
| [**pvc-capacity-forecast**](../scenarios/pvc-capacity-forecast/) | ❌ | ⚠️ | ✅ | — | `predict_linear` PVC runway → expand PVC before it fills |
| [**db-connection-saturation**](../scenarios/db-connection-saturation/) | ❌ | ✅ | ✅ | — | Connection leaker exhausts `max_connections` → identify the leaker among multiple workloads, restart it |
| [**cascading-service-failure**](../scenarios/cascading-service-failure/) | ❌ | ✅ | ✅ | — | One Postgres crash kills two dependent apps → rollback postgres; RO dedup blocks the second RR |
| [**etcd-defrag-forecast**](../scenarios/etcd-defrag-forecast/) | ❌ | ✅ | ✅ | Production | Fragmentation ratio predicted to degrade → rolling per-member defrag |
| [**cross-namespace-dependency**](../scenarios/cross-namespace-dependency/) | ❌ | ✅ | ✅ | — | Postgres crash in one namespace kills dependents in another → RCA must trace across the boundary |
| [**severity-misdirection**](../scenarios/severity-misdirection/) | ❌ | ✅ | ✅ | — | OOM-killed Postgres (P3) causes api-gateway crash-loop (P1) → must prioritize temporal causation over severity ranking |
| [**red-herring-noise**](../scenarios/red-herring-noise/) | ❌ | ✅ | ✅ | — | Postgres crash + an unrelated canary with a bad image tag → separate independent failures, don't let the canary pollute RCA |
| [**disk-pressure-emptydir**](../scenarios/disk-pressure-emptydir/) | ❌ | — | ✅ | Production | PostgreSQL on emptyDir fills disk → Ansible/AWX: `pg_dump`, PVC migration commit to Git, ArgoCD sync, `pg_restore` |
| [**prompt-injection**](../scenarios/prompt-injection/) | ✅ | ✅ | ✅ | — | Authority-impersonation payload in a ConfigMap → shadow agent detects it and blocks execution |
| [**alert-misdirection**](../scenarios/alert-misdirection/) | ✅ | ✅ | ✅ | Production | Misleading OOM narrative in the alert description → LLM resists it and rolls back instead |
| [**resource-contention**](../scenarios/resource-contention/) | ✅ | ⚠️ | ✅ | — | External actor reverts Kubernaut's fix → detect the ineffective-remediation chain via spec drift, escalate to human |
| [**operator-oomkill-informer**](../scenarios/operator-oomkill-informer/) | ❌ | ✅ | ✅ | Production | Unfiltered `controller-runtime` informer cache lets any `edit`-role user OOMKill the operator (CVE-class, [kubeflow/spark-operator#2878](https://github.com/kubeflow/spark-operator/pull/2878)) → `IncreaseMemoryLimits` |

### L3 Scenario Details

- **pvc-capacity-forecast** -- PoC for Kubernaut as the action layer for RHACM capacity forecasting. Uses `predict_linear` on `kubelet_volume_stats_used_bytes` to fire before the PVC fills. Requires a StorageClass with `allowVolumeExpansion: true` (tested with `lvms-vg1`). New ActionType: `ExpandPersistentVolumeClaim`. New workflow: `expand-pvc-v1`. Fleet mode is blocked on an upstream Kind kubelet regression ([kubernaut#2338](https://github.com/jordigilh/kubernaut/issues/2338), confirmed no workaround).
- **db-connection-saturation** -- L3 performance investigation. The LLM must correlate `pg_stat_activity_count` with per-client breakdowns to identify the leaker among multiple workloads. Uses `postgres_exporter` as a superuser sidecar to ensure metrics survive saturation. Workflows: `increase-db-connections-v1` (PatchConfiguration) and `scale-replicas-v1` (ScaleReplicas).
- **cascading-service-failure** -- Tests the RO's post-AI-analysis dedup path. Two RRs with different signal fingerprints converge when the LLM identifies the same `remediationTarget` (`Deployment/postgres`). The RO's `AcquireLock` + `CheckResourceBusy` ensures one WFE runs; the second RR is blocked with `ResourceBusy`. Reuses existing rollback workflows.
- **etcd-defrag-forecast** -- Predictive etcd defragmentation. Standalone 3-member etcd cluster with injected fragmentation. LLM investigates member health, quorum, and fragmentation ratio before deciding to defrag. Rolling defrag via `kubectl exec` with health checks between members. Manual approval required. New ActionType: `DefragEtcd`. New workflow: `defrag-etcd-v1`. Designed for migration to real cluster etcd once validated.
- **cross-namespace-dependency**, **severity-misdirection**, **red-herring-noise** -- address diagnostic capability gaps identified through coverage analysis; all three reuse existing rollback/restart workflows (no new ActionTypes or OCI bundles required).
- **resource-contention** -- fleet mode only exercises the alert-only half (`ContainerOOMKilling`); the external-actor/ineffective-remediation-chain narrative that defines this scenario needs a real remediation loop, which fleet's alert-only model doesn't run ([#423](https://github.com/jordigilh/kubernaut-demo-scenarios/issues/423)).

## Planned (not yet implemented)

- **machineset-failure** -- MachineSet/Machine failure scenario. Status: planned, no `run.sh` yet.
