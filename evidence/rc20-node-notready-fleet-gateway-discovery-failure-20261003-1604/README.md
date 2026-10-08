# RC20 Fleet node-notready failed run: stale MCP discovery

The temporary remote MCP pod was pinned to the spoke control-plane, so the
worker fault did not remove the bridge endpoint. Direct and externally queried
Envoy tools/list exposed `remote-cluster__*`, but the Gateway process retained
an MCP session whose tools/list contained only the 19 `hub__*` tools. Its
Prometheus adapter therefore rejected all four alert batch entries with:

`no tools found for cluster "remote-cluster" among 19 discovered tool names`

The run reached a firing `KubeNodeNotReady` alert but created no
RemediationRequest. The golden transcript was not modified.
