# Kubernaut Demo Scenarios

Demo scenarios for the [Kubernaut](https://github.com/jordigilh/kubernaut) AIOps platform. Each scenario showcases the full remediation lifecycle: from signal detection through AI analysis to automated workflow execution on a local Kind cluster.

> **Migration in progress**: Content is being migrated from [`kubernaut/deploy/demo/`](https://github.com/jordigilh/kubernaut/tree/main/deploy/demo). See the demo team for status.

## Repository Structure

```
scenarios/           # Individual demo scenarios (run.sh, manifests, workflows, media)
scripts/             # Shared helper scripts (Kind, monitoring, platform, recording)
helm/                # Helm values for kube-prometheus-stack and Kubernaut Kind overrides
credentials/         # LLM credential Secret examples (Vertex AI, Anthropic, OpenAI)
overlays/kind/       # Kind cluster configuration
```

## Platform Dependency

Scenarios deploy the Kubernaut platform via its Helm chart. During development, the chart is installed from the local kubernaut repository. For releases, it will be pulled from the official OCI container registry.

## Related Repositories

- [kubernaut](https://github.com/jordigilh/kubernaut) -- Platform source code and Helm chart
- [kubernaut-docs](https://github.com/jordigilh/kubernaut-docs) -- Documentation site
