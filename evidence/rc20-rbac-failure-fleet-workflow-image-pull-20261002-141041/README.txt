scenario=rbac-failure
attempt=2026-10-02 14:10:41 local
classification=fleet-environment-disk-exhaustion
outcome=run-scenario.sh timed out after 600s while polling WorkflowExecution; the workflow completed shortly afterward
primary_failure=remote spoke node/containerd had insufficient disk while pulling the RestoreRoleBinding workflow image; Kubernetes events recorded no space left on device and ImagePullBackOff
remediation=workflow eventually ran successfully, recreated RoleBinding metrics-collector, restarted the Deployment, and recovered metrics-collector to 1/1
upstream_status=not an upstream Kubernaut defect; Fleet ingestion, MCP discovery, AI analysis, workflow selection, remote execution, and remediation all completed
preservation=run log plus hub/spoke CRs, execution Job/Pod, logs, events, and post-remediation workload state
