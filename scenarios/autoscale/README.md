# Scenario #126: Cluster Autoscaling -- Add Node via kubeadm join

## Overview

This scenario demonstrates Kubernaut diagnosing pod scheduling failures caused by resource exhaustion across all cluster nodes, and remediating by provisioning a new Kind worker node via `kubeadm join`.

The architecture uses **split responsibility** (Option B), mirroring how cloud autoscalers work in production:

```
Production:
  WE Job → calls AWS/GCP/Azure API → cloud provisions VM → VM runs kubeadm join

Kind Demo (equivalent):
  WE Job → writes ScaleRequest ConfigMap → host-side provisioner detects it
                                            → podman run (create container)
                                            → podman exec (kubeadm join)
                                            → kubectl label (workload node)
  WE Job → waits for new Node Ready → verifies pods rescheduled
```

The WE Job runs **unprivileged inside Kubernetes**. It writes a scale request and waits. The host-side provisioner agent is the Kind-specific equivalent of Karpenter (EKS), NAP (GKE), or `cluster-autoscaler`.

## Prerequisites

- Kind cluster created with `overlays/kind/kind-cluster-config.yaml` (multi-node: control-plane + 1 worker)
- Podman available on the host (used by the provisioner agent)
- Kubernaut services deployed with HAPI configured for a real LLM backend
- `ProvisionNode` action type registered in DataStorage (migration 026)
- `provision-node-v1` workflow registered in the workflow catalog

## BDD Specification

```gherkin
Feature: Cluster Autoscaling via Node Provisioning

  Scenario: Pods stuck Pending due to resource exhaustion trigger node provisioning
    Given a Kind cluster with 1 control-plane and 1 worker node
      And an nginx Deployment "web-cluster" with 2 replicas running on the worker node
      And each replica requests 2Gi memory
      And the Kubernaut pipeline is active with a real LLM
      And the "provision-node-v1" workflow is registered in the catalog
      And the host-side provisioner agent is running

    When run.sh queries total allocatable memory across managed worker nodes
      And computes a replica count that exceeds total capacity (max_pods + 2)
      And scales the Deployment to that replica count
      And new pods enter Pending state with "Insufficient memory" events

    Then Prometheus fires KubePodSchedulingFailed alert after 2 minutes
      And Signal Processing enriches with node resource allocation data
      And the LLM identifies cluster-wide resource exhaustion as root cause
      And the LLM selects the ProvisionNode action type
      And Remediation Orchestrator creates a WorkflowExecution
      And the WE Job creates a ScaleRequest ConfigMap in kubernaut-system
      And the provisioner agent detects the request
      And the provisioner creates a new Kind node via podman + kubeadm join
      And the provisioner labels the new node kubernaut.ai/managed=true
      And the WE Job verifies the new node is Ready
      And previously-Pending pods schedule on the new node
      And EffectivenessAssessment confirms all pods are Running
```

## Automated Execution

```bash
./scenarios/autoscale/run.sh
```

This script:
1. Deploys the namespace, workload, and Prometheus rules
2. Starts the provisioner agent in the background
3. Queries allocatable memory and computes a replica count that exceeds node capacity
4. Scales the deployment to trigger Pending pods

## Manual Step-by-Step

```bash
# 1. Verify cluster has control-plane + 1 worker
kubectl get nodes

# 2. Deploy namespace and workload (2 replicas)
kubectl apply -f scenarios/autoscale/manifests/
kubectl wait --for=condition=Available deployment/web-cluster \
  -n demo-autoscale --timeout=60s

# 3. Deploy Prometheus alerting rules
kubectl apply -f scenarios/autoscale/manifests/prometheus-rule.yaml

# 4. Start the provisioner agent in background
./scenarios/autoscale/provisioner.sh &
PROVISIONER_PID=$!

# 5. Verify initial state (2 Running pods)
kubectl get pods -n demo-autoscale -o wide

# 6. Inject: scale beyond node capacity (compute dynamically or use a high count)
kubectl scale deployment/web-cluster --replicas=14 -n demo-autoscale

# 7. Verify some pods are Pending
kubectl get pods -n demo-autoscale   # some Running, rest Pending

# 8. Watch Kubernaut pipeline
kubectl get rr,sp,aa,we,ea -n kubernaut-system -w

# 9. Verify: new node appeared, all pods Running
kubectl get nodes                          # 3rd node visible
kubectl get pods -n demo-autoscale -o wide # distributed across nodes

# 10. Cleanup
kill $PROVISIONER_PID
./scenarios/autoscale/cleanup.sh
```

## Acceptance Criteria

- [ ] nginx Deployment manifests in `scenarios/autoscale/manifests/`
- [ ] WE Job workflow (remediate.sh) creates ScaleRequest and verifies fulfillment
- [ ] Host-side provisioner agent (provisioner.sh) watches and provisions nodes
- [ ] `deploy/remediation-workflows/autoscale/autoscale.yaml` with actionType `ProvisionNode` registered in DataStorage
- [ ] Prometheus alerting rule for `FailedScheduling` / `Insufficient` resources
- [ ] Full pipeline with real LLM: Gateway -> RO -> SP -> AA -> WE -> EM
- [ ] LLM identifies resource exhaustion and selects node provisioning workflow
- [ ] New node joins via kubeadm, `kubectl get nodes` shows it as Ready
- [ ] Previously Pending pods schedule on the new node
- [ ] `run.sh` automates the entire flow (including starting provisioner agent)
- [ ] README documents both automated and manual step-by-step execution
- [ ] Cleanup instructions for removing the extra node and provisioner

## Dynamic Scaling

`run.sh` computes the replica count at runtime:

1. Queries `allocatable.memory` from all nodes with `kubernaut.ai/managed=true`
2. Divides total allocatable by the per-pod request (2Gi) to get `max_pods`
3. Scales to `max_pods + 2` (minimum 8) to guarantee at least 2 pods stay Pending

This works regardless of host memory -- whether it's a Linux host exposing all RAM or a macOS Podman VM with a capped allocation.

## Platform Notes

### OCP

The `run.sh` script auto-detects the platform and applies the `overlays/ocp/` kustomization via `get_manifest_dir()`. The overlay:

- Adds `openshift.io/cluster-monitoring: "true"` to the demo namespace
- Swaps `nginx:1.27-alpine` to `nginxinc/nginx-unprivileged:1.27-alpine` (port 80 → 8080)
- Adjusts Service targetPort and liveness/readiness probes to match
- Removes the `release` label from `PrometheusRule`

OCP provides built-in metrics via the metrics server — no additional install needed. No manual steps required.

## Cleanup

```bash
./scenarios/autoscale/cleanup.sh
```

This removes the namespace, scale-request ConfigMap, kills the provisioner, and deletes dynamically provisioned node containers from Podman.

## Notes

- **Production analogy**: The provisioner agent is the Kind equivalent of Karpenter (EKS), NAP (GKE), or cluster-autoscaler. In production, the WE Job would call a cloud API directly instead of writing a ConfigMap.
- **Security**: The WE Job runs unprivileged inside K8s. Only the host-side agent (outside K8s) has Podman access.
- **EM target**: The `AffectedResource` should be the Deployment (pods now Running), not the cluster itself.
