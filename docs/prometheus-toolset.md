# Manual Prometheus Toolset Enablement

Several scenarios require the Kubernaut Agent Prometheus toolset so the LLM can query
Prometheus metrics during AI Analysis. When using `run.sh`, this is handled
automatically via `enable_prometheus_toolset()` and reverted by `cleanup.sh`.

If you are following the **Manual Step-by-Step** instructions, enable the toolset
before running the scenario.

## Kind

Add the `prometheus/metrics` toolset to `~/.kubernaut/sdk-config.yaml`:

```yaml
toolsets:
  prometheus/metrics:
    enabled: true
    config:
      prometheus_url: "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
```

Apply to the cluster and restart the Kubernaut Agent:

```bash
kubectl create configmap kubernaut-agent-sdk-config \
  --from-file=sdk-config.yaml=$HOME/.kubernaut/sdk-config.yaml \
  -n kubernaut-system --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/kubernaut-agent -n kubernaut-system
kubectl rollout status deployment/kubernaut-agent -n kubernaut-system --timeout=120s
```

## OCP

On OCP, the Prometheus URL uses HTTPS with a service-serving CA, and the
Kubernaut Agent service account needs `cluster-monitoring-view` RBAC.

### 1. Grant monitoring RBAC

```bash
KA_SA=$(kubectl get sa -n kubernaut-system -l app=kubernaut-agent \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "kubernaut-agent-sa")

kubectl create clusterrolebinding kubernaut-agent-monitoring-view \
  --clusterrole=cluster-monitoring-view \
  --serviceaccount="kubernaut-system:${KA_SA}" 2>/dev/null || true
```

### 2. Enable the toolset

```yaml
toolsets:
  prometheus/metrics:
    enabled: true
    config:
      prometheus_url: "https://prometheus-k8s.openshift-monitoring.svc:9091"
      prometheus_ssl_ca_file: "/etc/ssl/ka/service-ca.crt"
```

Apply and restart as shown in the Kind section above.

### 3. AlertManager RBAC (optional)

If the LLM needs AlertManager access (OCP kube-rbac-proxy requires resource-level
access on `monitoring.coreos.com/alertmanagers/api`):

```bash
kubectl get clusterrole kubernaut-alertmanager-view -o json \
  | python3 -c "
import json, sys
role = json.load(sys.stdin)
role['rules'].append({
    'apiGroups': ['monitoring.coreos.com'],
    'resources': ['alertmanagers/api'],
    'verbs': ['get']
})
json.dump(role, sys.stdout)
" | kubectl apply -f -
```

## Reverting

After the scenario, disable the toolset by setting `enabled: false` in
`sdk-config.yaml`, re-applying the ConfigMap, and restarting the Kubernaut Agent. The
`cleanup.sh` script does this automatically.
