[Home](../README.md) > Verification and Cleanup

# Verification and Cleanup

Commands for inspecting the remediation pipeline, cleaning up scenarios, and tearing down the cluster.

## Pipeline Status

### Check all platform pods
```bash
kubectl get pods -n kubernaut-system
kubectl get pods -A
```

### Check RemediationRequests
```bash
kubectl get remediationrequests -A
```

### Check AIAnalysis results
```bash
kubectl get aianalyses -A -o wide
```

### Check WorkflowExecutions
```bash
kubectl get workflowexecutions -A -o wide
```

### Check EffectivenessAssessments
```bash
kubectl get effectivenessassessments -A -o wide
```

### Check NotificationRequests
```bash
kubectl get notificationrequests -A -o wide
```

### Check workflow catalog
```bash
curl -s http://localhost:30081/api/v1/workflows | jq '.'
```

### Check audit events
```bash
curl -s http://localhost:30081/api/v1/audit-events | jq '.'
```

## Monitoring

### View Prometheus alerts
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/alerts | jq '.'
```

### View AlertManager alerts
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 &
curl -s http://localhost:9093/api/v2/alerts | jq '.'
```

## Scenario Cleanup

Each scenario deploys into its own namespace. To clean up after running:

```bash
# Per-scenario cleanup (if a cleanup.sh exists)
bash scenarios/stuck-rollout/cleanup.sh

# Or delete the namespace directly
kubectl delete namespace demo-rollout
```

## Teardown

Delete the entire Kind cluster:

```bash
kind delete cluster --name kubernaut-demo
```

This removes all resources. To recreate, run `./scripts/setup-demo-cluster.sh` again (see [Create the Cluster](setup.md#create-the-cluster)).
