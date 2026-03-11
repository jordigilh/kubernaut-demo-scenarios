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

### 2. Clone both repositories

The demo scenarios need the main Kubernaut repo as a sibling (the Helm chart is installed from source):

```bash
git clone https://github.com/jordigilh/kubernaut.git
git clone https://github.com/jordigilh/kubernaut-demo-scenarios.git
cd kubernaut-demo-scenarios
```

### 3. Configure your LLM provider

Kubernaut needs an LLM to analyze issues. Pick one provider and configure it:

```bash
mkdir -p ~/.kubernaut/helm
cp helm/llm-values.yaml.example ~/.kubernaut/helm/llm-values.yaml
```

Edit `~/.kubernaut/helm/llm-values.yaml` with your provider details. Example for Anthropic:

```yaml
holmesgptApi:
  llm:
    provider: "anthropic"
    model: "claude-sonnet-4-20250514"
```

See the [LLM Provider Configuration](docs/setup.md#llm-provider-configuration) guide for all supported providers: Vertex AI, Anthropic, OpenAI, and local models (Ollama, vLLM, LM Studio).

### 4. Create the cluster

This creates a Kind cluster, installs monitoring (Prometheus, Grafana), deploys the Kubernaut platform, and seeds the workflow catalog. Takes ~10 minutes on first run:

```bash
./scripts/setup-demo-cluster.sh
```

### 5. Apply LLM credentials

Once the cluster is running, apply your provider's API key as a Kubernetes Secret:

```bash
# Pick the example for your provider (anthropic, openai, or vertex-ai)
cp credentials/anthropic-example.yaml my-llm-credentials.yaml
# Edit with your actual API key
kubectl apply -f my-llm-credentials.yaml
kubectl rollout restart deployment/holmesgpt-api -n kubernaut-system
```

### 6. Run a scenario and watch it work

```bash
./scenarios/crashloop/run.sh
```

This deploys a misconfigured application that starts crash-looping. Within a few minutes, Kubernaut detects the issue, analyzes it, and rolls back to the last working version. Watch the pipeline progress:

```bash
kubectl get remediationrequests -A -w    # Signal detected
kubectl get aianalyses -A -w             # LLM analyzing
kubectl get workflowexecutions -A -w     # Fix applied
```

A successful run looks like:

```
NAMESPACE        NAME                    STATUS
demo-crashloop   crashloop-rr-abc123     Completed

NAMESPACE        NAME                    SELECTED-WORKFLOW          STATUS
demo-crashloop   crashloop-aa-abc123     rollback-deployment        Completed

NAMESPACE        NAME                    STATUS
demo-crashloop   crashloop-wfe-abc123    Succeeded
```

## What Just Happened?

When you ran the scenario, Kubernaut's remediation pipeline kicked in:

```
Prometheus alert fires (KubePodCrashLooping)
  -> Gateway creates a RemediationRequest
  -> SignalProcessing classifies severity, environment, priority
  -> AI Analysis investigates the root cause via LLM
  -> LLM selects the best remediation workflow from the catalog
  -> WorkflowExecution runs the fix (rollback, patch, restart, etc.)
  -> Notification delivers status updates
  -> EffectivenessMonitor verifies the fix actually worked
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
