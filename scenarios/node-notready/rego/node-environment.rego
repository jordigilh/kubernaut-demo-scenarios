package signalprocessing

import rego.v1

# Cluster-scoped resources (Node, PV, ClusterRole) have no namespace.
# The Go enricher serialises an empty NamespaceContext (name: ""), so the
# standard `not input.namespace.name` guard is never true — Rego treats ""
# as a defined value. These rules use an explicit `== ""` check instead.
environment := {"environment": "Production", "source": "workload-labels"} if {
	input.namespace.name == ""
	env := input.workload.labels["kubernaut.ai/environment"]
	lower(env) == "production"
}

environment := {"environment": "Staging", "source": "workload-labels"} if {
	input.namespace.name == ""
	env := input.workload.labels["kubernaut.ai/environment"]
	lower(env) == "staging"
}

environment := {"environment": "Development", "source": "workload-labels"} if {
	input.namespace.name == ""
	env := input.workload.labels["kubernaut.ai/environment"]
	lower(env) == "development"
}

environment := {"environment": "Test", "source": "workload-labels"} if {
	input.namespace.name == ""
	env := input.workload.labels["kubernaut.ai/environment"]
	lower(env) == "test"
}

# Custom labels fallback: extract team/tier from workload labels when
# namespace labels are absent (cluster-scoped resources).
labels := {"team": [team], "tier": [tier]} if {
	input.namespace.name == ""
	team := input.workload.labels["kubernaut.ai/team"]
	team != ""
	tier := input.workload.labels["kubernaut.ai/tier"]
	tier != ""
}

labels := {"team": [team]} if {
	input.namespace.name == ""
	team := input.workload.labels["kubernaut.ai/team"]
	team != ""
	not input.workload.labels["kubernaut.ai/tier"]
}
