scenario=rbac-failure
attempt=2026-10-02 01:26:23 local
classification=fleet-platform-no-rr
outcome=run.sh timed out waiting 120s for RemediationRequest; cleanup was skipped by the harness
primary_failure=hub gateway rejected Alertmanager batches while remote-cluster tool discovery was unavailable (no tools found / context canceled)
secondary_artifact=after Podman/Kubernetes recovery, stale Alertmanager state eventually created rr-220b295e549b-246f7c21 at 05:40Z; this was not created during the timed-out run and was admitted while authwebhook was unavailable
preservation=retry log, spoke fixture, hub pipeline state, gateway/Alertmanager logs and cluster events are retained
