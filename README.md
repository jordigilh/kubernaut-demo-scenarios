# Kubernaut Demo Scenarios

[Kubernaut](https://github.com/jordigilh/kubernaut) is an AIOps platform that automatically detects and remediates Kubernetes issues using LLM-driven analysis. These demo scenarios let you see it in action: run a scenario, break something on purpose, and watch Kubernaut fix it.

## Quick Start

### 1. Install tools

**macOS (Homebrew):**

```bash
brew install kind kubectl helm podman
```

**Linux:**

```bash
# Kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Podman — see https://podman.io/docs/installation#linux
```

> **Container runtime:** All demo scenarios are tested with [Podman](https://podman.io/). Docker may work but is untested.

### 2. Clone the demo scenarios

```bash
git clone https://github.com/jordigilh/kubernaut-demo-scenarios.git
cd kubernaut-demo-scenarios
```

The Kubernaut Helm chart is installed automatically from the OCI registry (`oci://quay.io/kubernaut-ai/charts/kubernaut`). If you have the [main Kubernaut repo](https://github.com/jordigilh/kubernaut) cloned as a sibling directory, the scripts will use the local chart instead (useful for development).

### 3. Configure your LLM provider

Kubernaut needs an LLM to analyze issues. Pick one provider and configure it.

**Quickstart** (Anthropic, OpenAI) -- set environment variables:

```bash
export KUBERNAUT_LLM_PROVIDER=anthropic
export KUBERNAUT_LLM_MODEL=claude-sonnet-4-20250514
```

**Advanced** (Vertex AI, Azure, local models, toolsets, MCP) -- use an SDK config file:

```bash
mkdir -p ~/.kubernaut
cp helm/sdk-config.yaml.example ~/.kubernaut/sdk-config.yaml
# Edit ~/.kubernaut/sdk-config.yaml with your provider details
```

See the [LLM Provider Configuration](docs/setup.md#llm-provider-configuration) guide for all supported providers: Vertex AI, Anthropic, OpenAI, and local models (Ollama, vLLM, LM Studio).

### 4. Create the cluster

<details>
<summary><strong>Option A: New Kind cluster</strong> (recommended for first-time users)</summary>

This creates a Kind cluster, installs monitoring (Prometheus, Grafana), deploys the Kubernaut platform, and seeds the workflow catalog. Takes ~10 minutes on first run:

```bash
./scripts/setup-demo-cluster.sh
```

> **Pre-release charts:** Helm's OCI resolver skips pre-release tags by default. To install a specific version (e.g. `1.1.0-rc1`), pass `--chart-version`:
>
> ```bash
> ./scripts/setup-demo-cluster.sh --chart-version 1.1.0-rc1
> ```

</details>

<details>
<summary><strong>Option B: Bring your own cluster</strong> (existing Kind or OCP)</summary>

If you already have a cluster, install the platform manually.

> **OCP prerequisites:** Before deploying the Helm chart on OCP:
>
> 1. **Storage:** A default StorageClass must exist (e.g. ODF, LVM Storage, or any CSI provisioner). The chart creates PVCs for postgresql (10Gi) and valkey (512Mi).
> 2. **cert-manager:** Install the `openshift-cert-manager-operator` from OperatorHub, then create the ClusterIssuer referenced by the chart:
>    ```bash
>    kubectl apply -f helm/ocp-cluster-issuer.yaml
>    ```
> 3. **Scenario-specific operators** (install from OperatorHub as needed):
>
> | Operator | Required for |
> |----------|-------------|
> | OpenShift GitOps | GitOps scenarios (gitops-drift, cert-failure-gitops, disk-pressure-emptydir) |
> | OpenShift Service Mesh (OSSM) | mesh-routing-failure |
> | AAP (Ansible Automation Platform) | disk-pressure-emptydir |

**Step B1: Create the namespace and apply LLM credentials first:**

```bash
# OCP: ensure you're logged in (oc login ...)
# Kind: ensure your kubeconfig points to the right cluster

kubectl create namespace kubernaut-system 2>/dev/null || true

# Pick your provider's credential template:
#   credentials/anthropic-example.yaml
#   credentials/openai-example.yaml
#   credentials/vertex-ai-example.yaml
cp credentials/<your-provider>-example.yaml my-llm-credentials.yaml
# Edit with your actual API key / credentials
kubectl apply -f my-llm-credentials.yaml
```

**Step B2: Install the platform.** Pick the command matching your LLM config from Step 3:

For **Kind** with quickstart (env vars):

```bash
helm upgrade --install kubernaut oci://quay.io/kubernaut-ai/charts/kubernaut \
    -n kubernaut-system --create-namespace \
    --values helm/kubernaut-kind-values.yaml \
    --set holmesgptApi.llm.provider=$KUBERNAUT_LLM_PROVIDER \
    --set holmesgptApi.llm.model=$KUBERNAUT_LLM_MODEL \
    --wait --timeout 10m
```

For **OCP** with quickstart (env vars):

```bash
helm upgrade --install kubernaut oci://quay.io/kubernaut-ai/charts/kubernaut \
    -n kubernaut-system --create-namespace \
    --values helm/kubernaut-ocp-values.yaml \
    --set holmesgptApi.llm.provider=$KUBERNAUT_LLM_PROVIDER \
    --set holmesgptApi.llm.model=$KUBERNAUT_LLM_MODEL \
    --wait --timeout 10m
```

For **either platform** with advanced config (SDK config file from Step 3):

```bash
helm upgrade --install kubernaut oci://quay.io/kubernaut-ai/charts/kubernaut \
    -n kubernaut-system --create-namespace \
    --values helm/kubernaut-<kind|ocp>-values.yaml \
    --set-file holmesgptApi.sdkConfigContent=$HOME/.kubernaut/sdk-config.yaml \
    --wait --timeout 10m
```

> **Chart version:** The latest stable version is installed by default. Helm's OCI resolver
> skips pre-release tags (e.g., `1.1.0-rc0`), so add `--version` to pin a specific release:
>
> ```
> --version 1.1.0-rc0
> ```

The chart seeds ActionTypes and RemediationWorkflows automatically (`demoContent.enabled: true` by default). No manual seeding needed.

**Optional: Slack notifications.** To receive alerts in Slack, create the webhook Secret and add the Slack values layer:

```bash
kubectl create secret generic slack-webhook -n kubernaut-system \
    --from-literal=webhook-url="https://hooks.slack.com/services/T.../B.../xxx"
# Then add --values helm/values-slack.yaml to your helm install command above.
```

</details>

### 5. Apply LLM credentials (Option A only)

If you used Option A (`setup-demo-cluster.sh`), apply your provider's API key now. Option B users already did this in Step B1.

```bash
# Pick your provider's template:
cp credentials/anthropic-example.yaml my-llm-credentials.yaml   # Anthropic
# cp credentials/openai-example.yaml my-llm-credentials.yaml    # OpenAI
# cp credentials/vertex-ai-example.yaml my-llm-credentials.yaml # Vertex AI

# Edit with your actual API key, then apply:
kubectl apply -f my-llm-credentials.yaml
kubectl rollout restart deployment/holmesgpt-api -n kubernaut-system
```

### 6. Run a scenario and watch it work

```bash
./scenarios/crashloop/run.sh
```

This deploys a misconfigured application that starts crash-looping. Within a few minutes, Kubernaut detects the issue, analyzes it, and rolls back to the last working version.

![Kubernaut detecting and remediating a CrashLoopBackOff](scenarios/crashloop/crashloop-lite.gif)

Watch the RemediationRequest progress through the pipeline:

```bash
kubectl get remediationrequests -n kubernaut-system -w
```

A successful run progresses through these phases:

```
NAME                          PHASE        OUTCOME      AGE
rr-b157a3a9e42f-1c2b5576     Processing                10s
rr-b157a3a9e42f-1c2b5576     Analyzing                 15s
rr-b157a3a9e42f-1c2b5576     Executing                 75s
rr-b157a3a9e42f-1c2b5576     Verifying                 85s
rr-b157a3a9e42f-1c2b5576     Completed    Remediated   6m
```

The RemediationRequest is the parent CRD that drives the entire pipeline. To inspect individual stages, see [Verification and Cleanup](docs/verification.md).

## What Just Happened?

When you ran the scenario, Kubernaut's remediation pipeline kicked in:

```
Prometheus alert fires (KubePodCrashLooping)
  -> Gateway creates a RemediationRequest
  -> SignalProcessing classifies severity, environment, priority
  -> AI Analysis investigates the root cause via LLM
  -> LLM selects the best remediation workflow from the catalog
  -> WorkflowExecution runs the fix (rollback, patch, restart, etc.)
  -> EffectivenessMonitor verifies the fix worked (or didn't)
  -> Notification delivers the final result including effectiveness assessment
```

Each of the 24 demo scenarios triggers a different alert and remediation path. Browse the full list in the [Scenario Catalog](docs/scenarios.md).

## Documentation

| Guide | Description |
|-------|-------------|
| **[Setup Guide](docs/setup.md)** | Prerequisites, LLM providers (Vertex AI, Anthropic, OpenAI, local), bootstrap flags, Slack notifications |
| **[Scenario Catalog](docs/scenarios.md)** | All 24 scenarios with alerts, fault injection, and remediation details |
| **[Verification and Cleanup](docs/verification.md)** | Inspect pipeline status, monitoring, per-scenario cleanup, teardown |
| **[Troubleshooting](docs/troubleshooting.md)** | Common issues and fixes |
| **[Building Workflow Images](docs/building.md)** | For contributors rebuilding scenario OCI images |
