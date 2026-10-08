scenario=network-policy-block
attempt=2026-10-02 14:51:27 local
classification=upstream-effectiveness-monitor-verification
outcome=remediation completed and workload recovered, but the run failed its expected Remediated outcome because EffectivenessAssessment ended VerificationTimedOut
primary_failure=EffectivenessMonitor accepted a non-finite pre-value from the histogram_quantile latency query as available data, computed metrics score NaN (4 of 5 Prometheus queries available), and failed status updates with json: unsupported value: NaN; the assessment expired despite health score 1 and alert score 1
remediation=fix-network-policy-v1 removed default-network-policy; traffic-gen and web-frontend were Running/Ready
upstream_status=upstream Kubernaut EffectivenessMonitor serialization/status defect, not a scenario or Fleet transport failure
preservation=run log plus hub RR/EA/events/controller log and spoke post-remediation resources/events
