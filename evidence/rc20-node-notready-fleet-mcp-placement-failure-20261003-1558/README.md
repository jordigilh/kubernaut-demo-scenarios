# RC20 Fleet node-notready failed run: MCP placement

The scenario deployed `demo-compute`, paused the spoke worker, and observed
`KubeNodeNotReady` on the hub Alertmanager. No RemediationRequest was created.

The temporary patched remote kube-mcp-server rollout placed its only replica on
the worker that the scenario pauses. The hand-authored hub bridge targets the
spoke control-plane NodePort, but the Service had no live endpoint while the
worker-hosted MCP pod was paused. Envoy AI Gateway therefore exposed only the
19 `hub__*` tools; Gateway could not resolve `remote-cluster` and rejected the
Prometheus batch before SignalProcessing could create an RR.

After preserving this evidence, the remote MCP deployment was moved to the
spoke control-plane and the worker was unpaused for the next attempt.
