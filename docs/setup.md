[Home](../README.md) > Setup Guide

# Setup Guide

This guide covers the full setup process for running Kubernaut demo scenarios. If you just want to get started quickly, see the [Quick Start](../README.md#quick-start) in the README.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Kind](https://kind.sigs.k8s.io/) | v0.30+ | Local Kubernetes cluster |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.34+ | Cluster interaction |
| [Helm](https://helm.sh/docs/intro/install/) | v3.14+ | Chart installation |
| Docker or Podman | recent | Container runtime for Kind |

**Memory:** ~9GB available for the Kind cluster.

**macOS (Homebrew):**
```bash
brew install kind kubectl helm
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
```

## Clone the Repositories

The demo scenarios require the main Kubernaut repository as a sibling directory (the Helm chart is installed from source during bootstrap):

```bash
git clone https://github.com/jordigilh/kubernaut.git
git clone https://github.com/jordigilh/kubernaut-demo-scenarios.git
cd kubernaut-demo-scenarios
```

Your directory layout should look like:

```
parent/
  kubernaut/                  # Main repo (Helm chart, CRDs, source)
  kubernaut-demo-scenarios/   # This repo (scenarios, scripts, credentials)
```

## LLM Provider Configuration

Kubernaut uses an LLM to analyze Kubernetes issues and select remediation workflows. You need credentials for at least one provider.

There are two configuration files involved:

1. **`~/.kubernaut/helm/llm-values.yaml`** -- Helm values that configure which provider, model, and endpoint to use. Read by `setup-demo-cluster.sh` during platform installation.
2. **`credentials/<provider>-example.yaml`** -- Kubernetes Secret with the actual API key. Applied to the cluster after bootstrap.

### Vertex AI (default)

Vertex AI is the default provider. You need a GCP project with the Vertex AI API enabled.

**Step 1: Configure Helm values**
```bash
mkdir -p ~/.kubernaut/helm
cp helm/llm-values.yaml.example ~/.kubernaut/helm/llm-values.yaml
```

Edit `~/.kubernaut/helm/llm-values.yaml`:
```yaml
holmesgptApi:
  llm:
    provider: "vertexai"
    model: "claude-sonnet-4-20250514"
    gcpProjectId: "your-gcp-project-id"
    gcpRegion: "us-east5"
```

**Step 2: Authenticate with GCP**
```bash
gcloud auth application-default login
```

**Step 3: Apply credentials Secret** (after bootstrap)
```bash
cp credentials/vertex-ai-example.yaml my-llm-credentials.yaml
# Edit my-llm-credentials.yaml with your GCP project ID
kubectl apply -f my-llm-credentials.yaml
kubectl rollout restart deployment/holmesgpt-api -n kubernaut-system
```

**Verify:**
```bash
kubectl logs -l app=holmesgpt-api -n kubernaut-system --tail=20
# Look for "LLM provider initialized" or similar startup message
```

### Anthropic

**Step 1: Configure Helm values**
```bash
mkdir -p ~/.kubernaut/helm
cp helm/llm-values.yaml.example ~/.kubernaut/helm/llm-values.yaml
```

Edit `~/.kubernaut/helm/llm-values.yaml`:
```yaml
holmesgptApi:
  llm:
    provider: "anthropic"
    model: "claude-sonnet-4-20250514"
```

**Step 2: Apply credentials Secret** (after bootstrap)
```bash
cp credentials/anthropic-example.yaml my-llm-credentials.yaml
# Edit my-llm-credentials.yaml with your Anthropic API key from https://console.anthropic.com/
kubectl apply -f my-llm-credentials.yaml
kubectl rollout restart deployment/holmesgpt-api -n kubernaut-system
```

**Verify:**
```bash
kubectl logs -l app=holmesgpt-api -n kubernaut-system --tail=20
```

### OpenAI

**Step 1: Configure Helm values**
```bash
mkdir -p ~/.kubernaut/helm
cp helm/llm-values.yaml.example ~/.kubernaut/helm/llm-values.yaml
```

Edit `~/.kubernaut/helm/llm-values.yaml`:
```yaml
holmesgptApi:
  llm:
    provider: "openai"
    model: "gpt-4o"
```

**Step 2: Apply credentials Secret** (after bootstrap)
```bash
cp credentials/openai-example.yaml my-llm-credentials.yaml
# Edit my-llm-credentials.yaml with your OpenAI API key from https://platform.openai.com/
kubectl apply -f my-llm-credentials.yaml
kubectl rollout restart deployment/holmesgpt-api -n kubernaut-system
```

**Verify:**
```bash
kubectl logs -l app=holmesgpt-api -n kubernaut-system --tail=20
```

### Local Models (OpenAI-compatible)

Any server that exposes an OpenAI-compatible API can be used: [Ollama](https://ollama.com/), [vLLM](https://docs.vllm.ai/), [LM Studio](https://lmstudio.ai/), or similar.

**Step 1: Start your local model server**

Example with Ollama:
```bash
ollama serve
ollama pull llama3.1
```

**Step 2: Configure Helm values**
```bash
mkdir -p ~/.kubernaut/helm
cp helm/llm-values.yaml.example ~/.kubernaut/helm/llm-values.yaml
```

Edit `~/.kubernaut/helm/llm-values.yaml`:
```yaml
holmesgptApi:
  llm:
    provider: "openai"
    model: "llama3.1"
    endpoint: "http://host.docker.internal:11434/v1"
```

> **Kind networking note:** Containers inside Kind cannot reach `localhost` on your host machine. Use `host.docker.internal` (Docker) or `host.containers.internal` (Podman) to reach the host's local server from inside the cluster.

**Step 3:** No credentials Secret is needed for local models. The bootstrap will configure the endpoint automatically.

**Verify:**
```bash
# Confirm the model server is reachable from inside the cluster
kubectl exec -it deploy/holmesgpt-api -n kubernaut-system -- \
  curl -s http://host.docker.internal:11434/v1/models | head -20
```

> **Note:** Local models may produce lower-quality analysis than commercial providers. For the best demo experience, use Vertex AI, Anthropic, or OpenAI.

## Create the Cluster

`setup-demo-cluster.sh` is the single entry point for creating the entire demo environment:

```bash
./scripts/setup-demo-cluster.sh
```

This takes ~10 minutes on first run and performs the following steps:

1. **Kind cluster** -- Creates a multi-node Kind cluster (`kubernaut-demo`) with port mappings for Gateway, DataStorage, and monitoring
2. **Monitoring stack** -- Installs kube-prometheus-stack (Prometheus, AlertManager, Grafana, kube-state-metrics) and the Kubernaut Grafana dashboard
3. **Infrastructure dependencies** -- cert-manager, metrics-server, Linkerd, blackbox-exporter, Gitea, ArgoCD
4. **Kubernaut platform** -- Installs the Helm chart from the sibling `kubernaut/charts/kubernaut/` directory, including CRDs, pre-install Secrets, and all 10 platform services
5. **Workflow catalog** -- Seeds ActionType CRDs and registers all scenario workflows in DataStorage

Every step is idempotent -- you can safely re-run the script if it fails partway through.

### Flags

| Flag | Purpose |
|------|---------|
| `--create-cluster` | Delete and recreate the Kind cluster from scratch |
| `--skip-infra` | Skip optional infrastructure (cert-manager, Linkerd, Gitea, ArgoCD) |
| `--with-awx` | Install AWX (required for the `memory-limits-gitops-ansible` scenario) |
| `--kind-config PATH` | Custom Kind cluster config (default: `scenarios/kind-config-multinode.yaml`) |

### Apply LLM Credentials

Once the bootstrap completes and pods are running, apply your LLM credentials Secret (see the provider-specific instructions above):

```bash
kubectl apply -f my-llm-credentials.yaml
kubectl rollout restart deployment/holmesgpt-api -n kubernaut-system
```

## Run a Scenario

Once the cluster is ready, pick any scenario and run it:

```bash
./scenarios/crashloop/run.sh
```

Each scenario's `run.sh` does three things:

1. **Validates** the platform is ready (`require_demo_ready`) -- exits with a clear error if `setup-demo-cluster.sh` hasn't been run
2. **Deploys** scenario-specific manifests (namespace, deployment, PrometheusRule, configmaps)
3. **Injects** the fault (bad config, bad image, CPU load, taint, etc.)

> `run.sh` does **not** create the Kind cluster or install the platform. That is handled by `setup-demo-cluster.sh`. If you see an error like `"ERROR: Cannot connect to Kubernetes cluster"`, run the bootstrap first.

Browse all 23 available scenarios in the [Scenario Catalog](scenarios.md).

> **Infrastructure dependencies:** Some scenarios require components like cert-manager, Linkerd, or AWX that are only installed when `setup-demo-cluster.sh` runs without `--skip-infra`. If a required component is missing, `run.sh` will exit with a clear error message. See the [dependency table](scenarios.md#dependencies) for details.

## Optional: Slack Notifications

To receive remediation notifications in Slack after the cluster is running:

1. Create a [Slack Incoming Webhook](https://api.slack.com/messaging/webhooks) for your workspace
2. Create the Secret in-cluster:

```bash
kubectl create secret generic slack-webhook \
  -n kubernaut-system \
  --from-literal=webhook-url="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

kubectl rollout restart deployment/notification-controller -n kubernaut-system
```

## Architecture

```
scripts/
  setup-demo-cluster.sh            # Bootstrap orchestrator (Kind + monitoring + platform + catalog)
  platform-helper.sh               # Helm chart deployment helpers
  monitoring-helper.sh             # kube-prometheus-stack, cert-manager, Linkerd, etc.
  kind-helper.sh                   # Kind cluster lifecycle
  seed-workflows.sh                # Register workflows in DataStorage
  seed-action-types.sh             # Apply ActionType CRDs
scenarios/
  <name>/
    run.sh                         # Deploy manifests + inject fault (requires bootstrapped cluster)
    cleanup.sh                     # Teardown script (if applicable)
    README.md                      # BDD spec, acceptance criteria, manual steps
    manifests/                     # Namespace, Deployment, Service, PrometheusRule
    workflow/                      # workflow-schema.yaml + Dockerfile for OCI image
helm/                              # Helm values: kube-prometheus-stack + Kubernaut Kind overrides
credentials/                       # LLM credential Secret examples
overlays/kind/                     # Kind cluster config (port mappings, node topology)
```
