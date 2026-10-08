# RC20 Fleet node-notready success with temporary MCP image

This run validated the complete Fleet path using the locally patched
`localhost/kubernetes-mcp-server:cluster-scope-pr1475-20261003-arm64` image,
pinned to the spoke control-plane so pausing the worker did not remove the
remote MCP endpoint.

- RR: `rr-427a0f3fccea-7842ed4f`
- Signal: `KubeNodeNotReady`, cluster `remote-cluster`
- Outcome: `Completed / Remediated`
- Workflow: `CordonDrainNode/cordon-drain-v1`
- AIAnalysis: 10 LLM turns, 24 tool calls, 75,488 tokens
- EffectivenessAssessment: `Completed / Full`
- Transcript: `transcript/node-notready-kubenodenotready.json`

The run used a temporary Valkey alias for the alert-shaped Node scope key:
`kubernaut:managed:remote-cluster:/v1/Node:demo-compute/<worker>`. RC20's
remote scope cache currently stores cluster-scoped Nodes under an empty
namespace, while Gateway passes the Prometheus `namespace=demo-compute` label.
The alias was deleted after the pipeline; the underlying empty-namespace key
remained untouched. This workaround is documented so the transcript is not
mistaken for proof that the RC20 scope-cache mismatch is fixed.

The existing `golden-transcripts/node-notready-kubenodenotready.json` was not
overwritten. Cleanup is captured separately after restoration.
