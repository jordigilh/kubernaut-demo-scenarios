[Home](../README.md) > Setup Guide

# Setup Guide

This guide covers the full setup process for running Kubernaut demo scenarios. If you just want to get started quickly, see the [Quick Start](../README.md#quick-start) in the README.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Kind](https://kind.sigs.k8s.io/) | v0.30+ | Local Kubernetes cluster |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.34+ | Cluster interaction |
| [Helm](https://helm.sh/docs/intro/install/) | v3.14+ | Chart installation |
| [Podman](https://podman.io/) (recommended) or Docker | recent | Container runtime for Kind (tested with Podman) |

**Memory:** ~9GB available for the Kind cluster.

### OCP prerequisites

When deploying on OpenShift (Option B), ensure the following before installing the Helm chart:

**Storage:** A default StorageClass must exist (e.g. ODF, LVM Storage, or any CSI provisioner). The chart creates PVCs for postgresql (10Gi) and valkey (512Mi). Verify with:

```bash
kubectl get storageclass
```

**cert-manager:** Install the `openshift-cert-manager-operator` from OperatorHub. The operator does **not** create any ClusterIssuers by default, so create the one referenced by the chart:

```bash
kubectl apply -f helm/ocp-cluster-issuer.yaml
```

This creates a `selfsigned-issuer` ClusterIssuer used by the chart's TLS configuration.

**Scenario-specific operators** (install from OperatorHub as needed):

| Operator | Required for | Install from |
|----------|-------------|-------------|
| OpenShift GitOps | GitOps scenarios (gitops-drift, cert-failure-gitops, disk-pressure-emptydir) | OperatorHub |
| OpenShift Service Mesh (OSSM) | mesh-routing-failure | OperatorHub |
| AAP (Ansible Automation Platform) | disk-pressure-emptydir | OperatorHub |

> **Note:** OCP provides Prometheus, AlertManager, and metrics-server via the built-in cluster monitoring stack. These do not need separate installation.

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

The v1.1.0 chart offers two configuration paths:

- **Quickstart** (Anthropic, OpenAI) -- set `KUBERNAUT_LLM_PROVIDER` and `KUBERNAUT_LLM_MODEL` environment variables. The chart auto-generates a minimal SDK config.
- **SDK config file** (Vertex AI, Azure, local models, toolsets, MCP) -- copy `helm/sdk-config.yaml.example` to `~/.kubernaut/sdk-config.yaml` and edit it. The bootstrap passes it via `--set-file holmesgptApi.sdkConfigContent=...`.

In both cases, API credentials are provided separately as a Kubernetes Secret (`credentials/<provider>-example.yaml`), applied to the cluster after bootstrap.

### Vertex AI (default)

Vertex AI is the default provider. You need a GCP project with the Vertex AI API enabled.

**Step 1: Create SDK config**
```bash
mkdir -p ~/.kubernaut
cp helm/sdk-config.yaml.example ~/.kubernaut/sdk-config.yaml
```

Edit `~/.kubernaut/sdk-config.yaml`:
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

**Step 1: Set environment variables**
```bash
export KUBERNAUT_LLM_PROVIDER=anthropic
export KUBERNAUT_LLM_MODEL=claude-sonnet-4-20250514
```

No SDK config file is needed -- the chart generates a minimal config from these values.

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

**Step 1: Set environment variables**
```bash
export KUBERNAUT_LLM_PROVIDER=openai
export KUBERNAUT_LLM_MODEL=gpt-4o
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

**Step 2: Create SDK config**

Local models require the `endpoint` field, which is only available in the SDK config (not the quickstart env vars):

```bash
mkdir -p ~/.kubernaut
cp helm/sdk-config.yaml.example ~/.kubernaut/sdk-config.yaml
```

Edit `~/.kubernaut/sdk-config.yaml`:
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
3. **Infrastructure dependencies** -- cert-manager, metrics-server, Istio, blackbox-exporter, Gitea, ArgoCD
4. **Kubernaut platform** -- Installs the Helm chart (from OCI registry, or local sibling if present), including CRDs, pre-install Secrets, and all 10 platform services
5. **Workflow catalog** -- Seeds ActionType CRDs and registers all scenario workflows in DataStorage

Every step is idempotent -- you can safely re-run the script if it fails partway through.

### Flags

| Flag | Purpose |
|------|---------|
| `--create-cluster` | Delete and recreate the Kind cluster from scratch |
| `--skip-infra` | Skip optional infrastructure (cert-manager, Istio, Gitea, ArgoCD) |
| `--with-awx` | Install AWX/AAP (required for `disk-pressure-emptydir`; OCP uses AAP, Kind uses AWX) |
| `--kind-config PATH` | Custom Kind cluster config (default: `scenarios/kind-config-multinode.yaml`) |
| `--chart-version VER` | Pin Helm chart version (e.g. `1.1.0-rc1`); required for pre-release tags |

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

Browse all 24 available scenarios in the [Scenario Catalog](scenarios.md).

> **Infrastructure dependencies:** Some scenarios require components like cert-manager, Istio, or AWX that are only installed when `setup-demo-cluster.sh` runs without `--skip-infra`. If a required component is missing, `run.sh` will exit with a clear error message. See the [dependency table](scenarios.md#dependencies) for details.

## Optional: Slack Notifications

To receive remediation notifications in Slack:

1. Create a [Slack Incoming Webhook](https://api.slack.com/messaging/webhooks) for your workspace
2. Save the webhook URL before running `setup-demo-cluster.sh`:

```bash
mkdir -p ~/.kubernaut/notification
echo "https://hooks.slack.com/services/YOUR/WEBHOOK/URL" > ~/.kubernaut/notification/slack-webhook.url
```

The bootstrap creates the `slack-webhook` Secret from this file. The Kind and OCP Helm values set `notification.slack.secretName: slack-webhook`, so the chart configures Slack routing automatically.

If the cluster is already running, create the Secret manually:

```bash
kubectl create secret generic slack-webhook \
  -n kubernaut-system \
  --from-literal=webhook-url="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
```

## Architecture

```
scripts/
  setup-demo-cluster.sh            # Bootstrap orchestrator (Kind + monitoring + platform + catalog)
  platform-helper.sh               # Platform detection (Kind vs OCP), kustomize overlay selection
  monitoring-helper.sh             # kube-prometheus-stack, cert-manager, Istio, etc.
  kind-helper.sh                   # Kind cluster lifecycle
  aap-helper.sh                   # AAP deployment (OCP)
  awx-helper.sh                   # AWX deployment (Kind)
  seed-workflows.sh                # Apply RemediationWorkflow CRDs (kubectl apply)
  seed-action-types.sh             # Apply ActionType CRDs
scenarios/
  gitops/scripts/
    setup-gitea.sh                 # Gitea Helm install (platform-aware: OCP adds SCC values + Route)
    setup-argocd.sh                # ArgoCD install (Kind) or credential provisioning only (OCP)
  <name>/
    run.sh                         # Deploy manifests + inject fault (requires bootstrapped cluster)
    cleanup.sh                     # Teardown script (if applicable)
    README.md                      # BDD spec, acceptance criteria, manual steps
    manifests/                     # Namespace, Deployment, Service, PrometheusRule
    overlays/ocp/                  # OCP kustomize overlay (restricted-v2 SCC, namespace overrides)
deploy/
  action-types/                    # ActionType CRD YAMLs (25 types)
  remediation-workflows/           # RemediationWorkflow CRDs + OCI image build assets
    <name>/
      <name>.yaml                  # RemediationWorkflow CRD
      Dockerfile.exec              # OCI exec image build context
      remediate.sh                 # Remediation script baked into exec image
helm/                              # Helm values: kube-prometheus-stack + Kubernaut Kind/OCP overrides
credentials/                       # LLM credential Secret examples
overlays/kind/                     # Kind cluster config (port mappings, node topology)
```
