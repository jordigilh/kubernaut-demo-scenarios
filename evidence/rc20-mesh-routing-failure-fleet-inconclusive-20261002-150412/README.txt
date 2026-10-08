scenario=mesh-routing-failure
mode=fleet
run_started=2026-10-02T19:04:25Z
run_log=run.log
remediation_request=rr-34d70cf37c03-8778e4a8
signal=IstioHighDenyRate
classification=environment/setup failure: KA/MCP investigation could not verify Prometheus, Alertmanager, or Istio security resources
pipeline=Completed/Inconclusive
selected_workflow=ScaleReplicas/scale-replicas-v1
workflow_target=demo-mesh/Deployment/traffic-gen
workflow_result=traffic-gen scaled to zero; deny-all-traffic remained
verification=Full assessment; health=0, alert=0, metrics=0; alert remained active
important_note=The harness was interrupted while AI analysis was in progress, but the platform continued the RR to terminal state. This is not a clean scenario success and no golden transcript was captured.
