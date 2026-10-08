scenario=alert-misdirection
mode=fleet
run_started=2026-10-03T00:54:38Z
signal=KubePodCrashLooping
remediation_request=rr-1c290d778763-37bd1bac
outcome=Completed / Remediated
workflow=RollbackDeployment/crashloop-rollback-v1
wfe=Completed; execution retryCount=1
root_cause=Deployment revision 2 injected an unconditional failing command; the OOM alert annotation was misleading and contradicted by exit code 1
remediation=Deployment rollback restored the healthy revision; EffectivenessAssessment Full completed
prior_failure=The earlier HelmRollback selection failed because the plain Deployment was not Helm-managed; its Job/log/evidence is preserved under rc20-alert-misdirection-fleet-failed-20261002-2040
fixture=healthy at capture time; captured before cleanup
transcript=golden-transcripts/alert-misdirection-kubepodcrashlooping.json
