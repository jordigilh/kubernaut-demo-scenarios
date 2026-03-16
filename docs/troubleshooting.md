[Home](../README.md) > Troubleshooting

# Troubleshooting

Common issues when running demo scenarios and how to resolve them.

## Pods stuck in ImagePullBackOff

Images are pulled from `quay.io/kubernaut-ai/`. Check that the Kind cluster has internet access and the image tag exists:
```bash
kubectl describe pod <pod-name> -n kubernaut-system
```

## PostgreSQL not starting

Check pod events:
```bash
kubectl describe pod -l app=postgresql -n kubernaut-system
```

## HolmesGPT API errors

Check logs for LLM credential issues:
```bash
kubectl logs -l app=holmesgpt-api -n kubernaut-system
```

Common causes:
- Missing or incorrect API key in the `llm-credentials` Secret
- Wrong provider/model in `~/.kubernaut/helm/sdk-config.yaml`
- For local models: endpoint unreachable from inside the Kind cluster (use `host.docker.internal` instead of `localhost`)

See the [LLM Provider Configuration](setup.md#llm-provider-configuration) guide for setup instructions.

## No RemediationRequests created

1. Check Gateway logs: `kubectl logs -l app=gateway -n kubernaut-system`
2. Verify the scenario namespace has the `kubernaut.ai/managed: "true"` label (each scenario's `namespace.yaml` sets this)

## Prometheus not scraping metrics

Check Prometheus targets:
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {scrapeUrl, health}'
```

## AuthWebhook rejecting requests

Check webhook cert validity:
```bash
kubectl get secret authwebhook-tls -n kubernaut-system
kubectl logs -l app.kubernetes.io/name=authwebhook -n kubernaut-system
```

## Scenario run.sh exits with "ERROR: Cannot connect to Kubernetes cluster"

The Kind cluster hasn't been created yet. Run the bootstrap first:
```bash
./scripts/setup-demo-cluster.sh
```

## Scenario run.sh exits with "ERROR: cert-manager is not installed"

The scenario requires an infrastructure component that was skipped. Re-run the bootstrap without `--skip-infra`:
```bash
./scripts/setup-demo-cluster.sh
```

See the [dependency table](scenarios.md#dependencies) for which scenarios need which components.
