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

## Kubernaut Agent errors

Check logs for LLM credential issues:
```bash
kubectl logs -l app=kubernaut-agent -n kubernaut-system
```

Common causes:
- Missing or incorrect API key in the `llm-credentials` Secret
- Wrong provider/model in `~/.kubernaut/sdk-config.yaml` (or `KUBERNAUT_LLM_PROVIDER`/`KUBERNAUT_LLM_MODEL` env vars)
- For local models: endpoint unreachable from inside the Kind cluster (use `host.docker.internal` instead of `localhost`)

See the [LLM Provider Configuration](setup.md#llm-provider-configuration) guide for setup instructions.

## No RemediationRequests created

1. Check Gateway logs: `kubectl logs -l app=gateway -n kubernaut-system`
2. Check Event Exporter logs: `kubectl logs -l app=event-exporter -n kubernaut-system`
3. Verify the scenario namespace has the `kubernaut.ai/managed: "true"` label (each scenario's `namespace.yaml` sets this)

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

## Helm upgrade fails with CRD field manager conflict

When re-installing or upgrading the Kubernaut Helm chart after a previous install (or after manually applying CRDs via `kubectl apply`), you may see:

```
Error: failed to install CRD crds/kubernaut.ai_aianalyses.yaml:
Apply failed with 1 conflict: conflict with "kubectl": .spec.versions
```

This happens because Helm uses server-side apply and detects that `kubectl` (or a previous Helm install) owns the CRD fields.

**Fix:** Force-apply the CRDs first, then install with `--skip-crds`:

```bash
CRD_DIR=$(mktemp -d)
helm pull oci://quay.io/kubernaut-ai/charts/kubernaut --version <version> --untar --untardir "$CRD_DIR"
kubectl apply -f "$CRD_DIR/kubernaut/crds/" --server-side --force-conflicts
rm -rf "$CRD_DIR"

# Then install with --skip-crds
helm upgrade --install kubernaut oci://quay.io/kubernaut-ai/charts/kubernaut \
    --version <version> \
    -n kubernaut-system --create-namespace \
    --values helm/kubernaut-ocp-values.yaml \
    --skip-crds \
    --wait --timeout 10m
```

## Helm upgrade fails with SDK ConfigMap conflict

After using `enable_prometheus_toolset()` (from `platform-helper.sh`) or manually patching the `kubernaut-agent-sdk-config` ConfigMap, a subsequent `helm upgrade` may fail with:

```
Apply failed with 1 conflict: conflict with "kubectl-patch" using v1: .data.sdk-config.yaml
```

**Fix:** The `enable_prometheus_toolset()` function (as of #229) now applies changes with Helm ownership annotations to prevent this. If you encounter this after a manual `kubectl patch`, re-adopt the ConfigMap for Helm:

```bash
kubectl annotate configmap kubernaut-agent-sdk-config -n kubernaut-system \
    meta.helm.sh/release-name=kubernaut \
    meta.helm.sh/release-namespace=kubernaut-system --overwrite
```

Then retry `helm upgrade`.
