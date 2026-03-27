[Home](../README.md) > Setup Guide

# Setup Guide

This guide covers the full setup process for running Kubernaut demo scenarios. If you just want to get started quickly, see the [Quick Start](../README.md#quick-start) in the README.

There are two deployment paths:

- **Option A** -- Run `setup-demo-cluster.sh` to create a new Kind cluster with everything pre-configured (recommended for first-time users).
- **Option B** -- Bring your own cluster (existing Kind or OpenShift) and install the platform manually via Helm.

This guide covers both. Steps marked "(Option B only)" can be skipped if you use the bootstrap script.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Kind](https://kind.sigs.k8s.io/) | v0.30+ | Local Kubernetes cluster |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.34+ | Cluster interaction |
| [Helm](https://helm.sh/docs/intro/install/) | v3.14+ | Chart installation |
| [Podman](https://podman.io/) (recommended) or Docker | recent | Container runtime for Kind (tested with Podman) |

**Memory:** ~9GB available for the Kind cluster.

### Installing tools

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
```

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
| OpenShift GitOps | GitOps scenarios (gitops-drift, cert-failure-gitops, disk-pressure-emptydir, memory-limits-gitops-ansible) | OperatorHub |
| OpenShift Service Mesh (OSSM) | mesh-routing-failure | OperatorHub |
| AWX/AAP | disk-pressure-emptydir, memory-limits-gitops-ansible | `awx-helper.sh` (AAP: `aap-helper.sh` + license) |

> **Note:** OCP provides Prometheus, AlertManager, and metrics-server via the built-in cluster monitoring stack. These do not need separate installation.

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
  provider: "vertex_ai"
  model: "claude-sonnet-4"
  gcp_project_id: "your-gcp-project-id"
  gcp_region: "us-east5"
```

> **Note:** Vertex AI requires the undated model name (`claude-sonnet-4`). The dated version (`claude-sonnet-4-20250514`) is only valid for direct Anthropic API calls.

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
4. **Kubernaut platform** -- Pre-creates required Secrets (`postgresql-secret`, `valkey-secret`, `llm-credentials`, `slack-webhook`), then installs the Helm chart (from OCI registry, or local sibling if present), including CRDs and all 10 platform services
5. **Workflow catalog** -- Seeds ActionType CRDs and registers all scenario workflows in DataStorage

Every step is idempotent -- you can safely re-run the script if it fails partway through.

### Kind Node Topology for Node-Drain Scenarios

Scenarios that cordon or drain worker nodes (`pdb-deadlock`, `pending-taint`, `node-notready`) need pods to reschedule to the control-plane node. `setup-demo-cluster.sh` handles this automatically, but the two requirements are worth understanding:

1. **Control-plane label** — `kind-config-multinode.yaml` labels the control-plane with `kubernaut.ai/managed=true` so it satisfies the `nodeSelector` used by workload deployments. Without this label, evicted pods stay Pending after a drain.

2. **Control-plane taint** — Kind applies `node-role.kubernetes.io/control-plane:NoSchedule` to the control-plane by default. The bootstrap removes this taint at cluster creation time. Without this, neither workload pods nor WorkflowExecution jobs can schedule on the control-plane.

If you create a cluster manually (without the bootstrap script), apply both:

```bash
kubectl label node <control-plane-node> kubernaut.ai/managed=true
kubectl taint nodes <control-plane-node> node-role.kubernetes.io/control-plane:NoSchedule-
```

> **Note:** kubernaut#498 tracks adding control-plane tolerations to WFE jobs so that taint removal is no longer required for remediation jobs.

### Flags

| Flag | Purpose |
|------|---------|
| `--create-cluster` | Delete and recreate the Kind cluster from scratch |
| `--skip-infra` | Skip optional infrastructure (cert-manager, Istio, Gitea, ArgoCD) |
| `--with-awx` | Install AWX (required for OCP-only Ansible-engine scenarios: `disk-pressure-emptydir`, `memory-limits-gitops-ansible`) |
| `--kind-config PATH` | Custom Kind cluster config (default: `scenarios/kind-config-multinode.yaml`) |
| `--chart-version VER` | Pin Helm chart version (e.g. `1.1.0-rc1`); required for pre-release tags |

### AWX/AAP Ansible Engine Configuration

When using `--with-awx` or configuring AAP manually (`aap-helper.sh --configure-only`),
the helper scripts automatically:

1. Create an API token and store it as a Kubernetes Secret (`awx-api-token` or `aap-api-token`)
2. Patch the `workflowexecution-config` ConfigMap with the `ansible:` engine block
3. **Grant RBAC** for the WE controller ServiceAccount to read the token secret
4. Restart the WE controller to pick up the new configuration

> **Important:** The WE controller reads the token secret at startup to register the
> ansible executor. Without the RBAC grant (Role + RoleBinding), the ansible engine
> is silently skipped and WorkflowExecutions with `engine: ansible` fail with
> `unsupported execution engine`. If you configure the ansible engine manually
> (without the helper scripts), ensure you create the RBAC:
>
> ```bash
> kubectl create role <secret-name>-reader \
>   --verb=get --resource=secrets --resource-name=<secret-name> \
>   -n kubernaut-system
> kubectl create rolebinding <secret-name>-reader \
>   --role=<secret-name>-reader \
>   --serviceaccount=kubernaut-system:workflowexecution-controller \
>   -n kubernaut-system
> ```

### Pre-create Database Secrets (Option B only)

> **Recommended on v1.1.0-rc13** (prevents credential drift on rollback),
> **required on v1.1.0-rc14+** where the chart no longer auto-generates database
> credentials (kubernaut#557, #243). Option A handles this automatically.
> **Run these commands before `helm install`** (see README Step B1 for the full ordering).

```bash
kubectl create namespace kubernaut-system 2>/dev/null || true

# PostgreSQL + DataStorage (consolidated single secret)
PG_PASSWORD=$(openssl rand -base64 24)
kubectl create secret generic postgresql-secret \
  -n kubernaut-system \
  --from-literal=POSTGRES_USER=slm_user \
  --from-literal=POSTGRES_PASSWORD="$PG_PASSWORD" \
  --from-literal=POSTGRES_DB=action_history \
  --from-literal=db-secrets.yaml="$(printf 'username: "slm_user"\npassword: "%s"' "$PG_PASSWORD")"

# Valkey
VALKEY_PASSWORD=$(openssl rand -base64 24)
kubectl create secret generic valkey-secret \
  -n kubernaut-system \
  --from-literal=VALKEY_PASSWORD="$VALKEY_PASSWORD" \
  --from-literal=valkey-secrets.yaml="$(printf 'password: "%s"' "$VALKEY_PASSWORD")"
```

These secrets are stable across upgrades -- `helm upgrade` will not overwrite them.

### Apply LLM Credentials

Apply your LLM credentials Secret (see the provider-specific instructions above):

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

> **Remote execution:** When running scenarios over SSH, use `-tt` to force TTY
> allocation for real-time output: `ssh -tt host "su - user -c './run.sh all'"`

## AlertManager Configuration (Option B only)

Option A (`setup-demo-cluster.sh`) automatically configures AlertManager to route demo scenario alerts to the Kubernaut Gateway. Option B users must configure this manually -- without it, Prometheus alerts fire but never reach the pipeline.

### Kind (kube-prometheus-stack)

Install kube-prometheus-stack with the provided values file, which pre-configures the Gateway webhook receiver and `demo-*` namespace routing:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    --values helm/kube-prometheus-stack-values.yaml \
    --wait --timeout 5m
```

If you already have kube-prometheus-stack installed, add the following to your AlertManager config:
- A `gateway-webhook` receiver with `url: http://gateway-service.kubernaut-system.svc.cluster.local:8080/api/v1/signals/prometheus`
- A route matching `namespace: "demo-.*"` to that receiver
- A route matching `alertname: KubeNodeNotReady` for cluster-scoped alerts

See `helm/kube-prometheus-stack-values.yaml` for the full config.

### OCP (openshift-monitoring)

Patch the cluster monitoring AlertManager with the provided config:

```bash
kubectl -n openshift-monitoring create secret generic alertmanager-main \
    --from-file=alertmanager.yaml=helm/ocp-alertmanager-config.yaml \
    --dry-run=client -o yaml | kubectl apply -f -
```

This adds a webhook route for `demo-*` namespace alerts and `KubeNodeNotReady` to the Kubernaut Gateway, while preserving OCP's default alert routing.

> **Note:** The `alertmanager-main` Secret is managed by the cluster monitoring operator. If you later reconfigure cluster monitoring, you may need to re-apply this patch.

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
  awx-helper.sh                   # AWX deployment (Kind + OCP, recommended)
  aap-helper.sh                   # AAP deployment (OCP only, requires Red Hat subscription)
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
