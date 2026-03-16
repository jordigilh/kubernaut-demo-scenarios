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

## Clone the Repository

```bash
git clone https://github.com/jordigilh/kubernaut-demo-scenarios.git
cd kubernaut-demo-scenarios
```

The Kubernaut Helm chart is installed automatically from the OCI registry (`oci://quay.io/kubernaut-ai/charts/kubernaut`). If you have the [main Kubernaut repo](https://github.com/jordigilh/kubernaut) cloned as a sibling directory, the scripts will use the local chart instead (useful for development).

## LLM Provider Configuration

Kubernaut uses an LLM to analyze Kubernetes issues and select remediation workflows. You need credentials for at least one provider.

### Quickstart (env vars) -- OpenAI, Anthropic, etc.

For providers that use a simple API key, set two environment variables before running `setup-demo-cluster.sh`:

```bash
export KUBERNAUT_LLM_PROVIDER=openai    # or: anthropic
export KUBERNAUT_LLM_MODEL=gpt-4o       # or: claude-sonnet-4-20250514
```

After the cluster is up, create the credentials Secret and restart the API pod:

```bash
# OpenAI
kubectl create secret generic llm-credentials \
  --from-literal=OPENAI_API_KEY=sk-... -n kubernaut-system

# Anthropic
kubectl create secret generic llm-credentials \
  --from-literal=ANTHROPIC_API_KEY=sk-ant-... -n kubernaut-system

# Restart to pick up new credentials
kubectl rollout restart deployment/holmesgpt-api -n kubernaut-system
```

**Verify:**
```bash
kubectl logs -l app=holmesgpt-api -n kubernaut-system --tail=20
```

### Advanced: Vertex AI

Vertex AI requires `gcp_project_id` and `gcp_region`, which cannot be set via env vars. Use the SDK config file instead:

**Step 1: Configure SDK config**
```bash
mkdir -p ~/.kubernaut/helm
cp helm/sdk-config.yaml.example ~/.kubernaut/helm/sdk-config.yaml
```

Edit `~/.kubernaut/helm/sdk-config.yaml`:
```yaml
llm:
  provider: "vertexai"
  model: "claude-sonnet-4-20250514"
  gcp_project_id: "your-gcp-project-id"
  gcp_region: "us-east5"
```

**Step 2: Authenticate with GCP**
```bash
gcloud auth application-default login
```

`platform-helper.sh` automatically detects the SDK config file and ADC credentials, creates the `llm-credentials` Secret with Vertex AI project/region, and passes the SDK config to the chart via `--set-file`.

**Verify:**
```bash
kubectl logs -l app=holmesgpt-api -n kubernaut-system --tail=20
```

### Advanced: Local Models (OpenAI-compatible)

Any server that exposes an OpenAI-compatible API can be used: [Ollama](https://ollama.com/), [vLLM](https://docs.vllm.ai/), [LM Studio](https://lmstudio.ai/), or similar.

**Step 1: Start your local model server**

Example with Ollama:
```bash
ollama serve
ollama pull llama3.1
```

**Step 2: Configure SDK config**
```bash
mkdir -p ~/.kubernaut/helm
cp helm/sdk-config.yaml.example ~/.kubernaut/helm/sdk-config.yaml
```

Edit `~/.kubernaut/helm/sdk-config.yaml`:
```yaml
llm:
  provider: "openai"
  model: "llama3.1"
  endpoint: "http://host.docker.internal:11434/v1"
```

> **Kind networking note:** Containers inside Kind cannot reach `localhost` on your host machine. Use `host.docker.internal` (Docker) or `host.containers.internal` (Podman) to reach the host's local server from inside the cluster.

**Step 3:** No credentials Secret is needed for local models. The bootstrap will configure the endpoint automatically.

**Verify:**
```bash
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

1. **Kind cluster** -- Creates a multi-node Kind cluster (`kubernaut-demo`) with port mappings for monitoring dashboards (Grafana)
2. **Monitoring stack** -- Installs kube-prometheus-stack (Prometheus, AlertManager, Grafana, kube-state-metrics) and the Kubernaut Grafana dashboard
3. **Infrastructure dependencies** -- cert-manager, metrics-server, Istio, blackbox-exporter, Gitea, ArgoCD
4. **Kubernaut platform** -- Installs the Helm chart (from OCI registry, or local sibling if present), including CRDs, auto-generated infrastructure Secrets, LLM provider configuration, and all 10 platform services. The chart also embeds all 25 ActionTypes and 20 RemediationWorkflows when `demoContent.enabled=true` (the default).

Every step is idempotent -- you can safely re-run the script if it fails partway through.

### Flags

| Flag | Purpose |
|------|---------|
| `--create-cluster` | Delete and recreate the Kind cluster from scratch |
| `--skip-infra` | Skip optional infrastructure (cert-manager, Istio, Gitea, ArgoCD) |
| `--with-awx` | Install AWX/AAP (required for `disk-pressure-emptydir`; OCP uses AAP, Kind uses AWX) |
| `--kind-config PATH` | Custom Kind cluster config (default: `scenarios/kind-config-multinode.yaml`) |

### Apply LLM Credentials

Once the bootstrap completes and pods are running, create the LLM credentials Secret if you haven't already (see the provider-specific instructions in [LLM Provider Configuration](#llm-provider-configuration)):

```bash
# Example for OpenAI:
kubectl create secret generic llm-credentials \
  --from-literal=OPENAI_API_KEY=sk-... -n kubernaut-system

# Restart to pick up new credentials
kubectl rollout restart deployment/holmesgpt-api -n kubernaut-system
```

The setup script prints provider-specific instructions at the end if the Secret is missing.

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

Browse all 24 available scenarios in the [Scenario Catalog](scenarios.md).

> **Infrastructure dependencies:** Some scenarios require components like cert-manager, Istio, or AWX that are only installed when `setup-demo-cluster.sh` runs without `--skip-infra`. If a required component is missing, `run.sh` will exit with a clear error message. See the [dependency table](scenarios.md#dependencies) for details.

## Optional: Slack Notifications

To receive remediation notifications in Slack:

**Automatic setup (before bootstrap):**

1. Create a [Slack Incoming Webhook](https://api.slack.com/messaging/webhooks) for your workspace
2. Save the webhook URL:

```bash
mkdir -p ~/.kubernaut/notification
echo "https://hooks.slack.com/services/YOUR/WEBHOOK/URL" > ~/.kubernaut/notification/slack-webhook.url
```

3. Optionally set the channel:

```bash
export KUBERNAUT_SLACK_CHANNEL="#demo-notifications"
```

`platform-helper.sh` automatically creates the `slack-webhook` Secret and passes `--set notification.slack.secretName=slack-webhook` to the chart during install.

**Manual setup (after bootstrap):**

```bash
kubectl create secret generic slack-webhook \
  -n kubernaut-system \
  --from-literal=webhook-url="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

helm upgrade kubernaut <chart-ref> -n kubernaut-system \
  --reuse-values \
  --set notification.slack.secretName=slack-webhook
```

## Architecture

```
scripts/
  setup-demo-cluster.sh            # Bootstrap orchestrator (Kind + monitoring + platform + catalog)
  platform-helper.sh               # Platform detection (Kind vs OCP), Helm install, LLM/Slack config
  monitoring-helper.sh             # kube-prometheus-stack, cert-manager, Istio, etc.
  kind-helper.sh                   # Kind cluster lifecycle
  aap-helper.sh                   # AWX/AAP deployment and playbook registration
scenarios/
  <name>/
    run.sh                         # Deploy manifests + inject fault (requires bootstrapped cluster)
    cleanup.sh                     # Teardown script (if applicable)
    README.md                      # BDD spec, acceptance criteria, manual steps
    manifests/                     # Namespace, Deployment, Service, PrometheusRule
    overlays/ocp/                  # OCP kustomize overlay (restricted-v2 SCC, namespace overrides)
    workflow/                      # workflow-schema.yaml + Dockerfile for OCI image
deploy/
  action-types/                    # ActionType CRD YAMLs (25 types)
helm/                              # Helm values: kube-prometheus-stack + Kubernaut Kind/OCP overrides
credentials/                       # LLM credential Secret examples
overlays/kind/                     # Kind cluster config (port mappings, node topology)
```
