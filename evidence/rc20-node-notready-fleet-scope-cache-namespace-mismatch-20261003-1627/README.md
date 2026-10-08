# RC20 Fleet node-notready failed run: remote scope cache namespace mismatch

The temporary patched kube-mcp-server was running on the spoke control-plane,
so pausing the worker did not remove the MCP bridge endpoint. The run reached
an active `KubeNodeNotReady` alert, but Gateway rejected the signal as
`unmanaged_resource`; no `demo-compute` RemediationRequest was created.

Authenticated FMC scope checks reproduced the failure:

- `Node`, `namespace=demo-compute`: `{"managed":false}`
- the same Node with an empty namespace: `{"managed":true}`

The cache contains the cluster-scoped Node key with an empty namespace. The
Prometheus alert nevertheless carries `namespace=demo-compute`, and the
current RC20 remote scope-cache client uses that namespace verbatim instead of
normalizing it for cluster-scoped kinds. This is separate from the patched MCP
server's namespace-ignoring read fix. The golden transcript was not modified.
