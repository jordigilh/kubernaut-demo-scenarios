# Kubernaut Demo Scenarios

[Kubernaut](https://github.com/jordigilh/kubernaut) is an AIOps platform that automatically detects and remediates Kubernetes issues using LLM-driven analysis. These demo scenarios let you see it in action: run a scenario, break something on purpose, and watch Kubernaut fix it.

## Quick Start

### 1. Install tools

```bash
brew install kind kubectl helm    # macOS
```

<details>
<summary>Linux / other platforms</summary>

See the [Setup Guide](docs/setup.md#prerequisites) for detailed installation instructions.

</details>

### 2. Clone the demo scenarios

```bash
git clone https://github.com/jordigilh/kubernaut-demo-scenarios.git
cd kubernaut-demo-scenarios
```

The Kubernaut Helm chart is installed automatically from the OCI registry (`oci://quay.io/kubernaut-ai/charts/kubernaut`). If you have the [main Kubernaut repo](https://github.com/jordigilh/kubernaut) cloned as a sibling directory, the scripts will use the local chart instead (useful for development).

### 3. Configure your LLM provider

Kubernaut needs an LLM to analyze issues. Set your provider and model via environment variables:

```bash
export KUBERNAUT_LLM_PROVIDER=openai    # or: anthropic, vertexai, bedrock
export KUBERNAUT_LLM_MODEL=gpt-4o       # or: claude-sonnet-4-20250514, gemini-2.0-flash, etc.
```

<details>
<summary>Advanced: Vertex AI or custom endpoint (SDK config file)</summary>

Vertex AI requires additional fields (`gcp_project_id`, `gcp_region`) that cannot be set via env vars. For Vertex AI or multi-model setups, use the SDK config file instead:

```bash
mkdir -p ~/.kubernaut/helm
cp helm/sdk-config.yaml.example ~/.kubernaut/helm/sdk-config.yaml
# Edit with your Vertex AI project/region, then run setup.
```

See the [LLM Provider Configuration](docs/setup.md#llm-provider-configuration) guide for details.

</details>

### 4. Create the cluster

This creates a Kind cluster, installs monitoring (Prometheus, Grafana), and deploys the Kubernaut platform including all demo ActionTypes and RemediationWorkflows. Takes ~10 minutes on first run:

```bash
./scripts/setup-demo-cluster.sh
```

### 5. Apply LLM credentials

Once the cluster is running, create the LLM credentials Secret with your API key:

```bash
# OpenAI
kubectl create secret generic llm-credentials \
  --from-literal=OPENAI_API_KEY=sk-... -n kubernaut-system

# Anthropic
kubectl create secret generic llm-credentials \
  --from-literal=ANTHROPIC_API_KEY=sk-ant-... -n kubernaut-system
```

The setup script prints provider-specific instructions if credentials are missing.

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
