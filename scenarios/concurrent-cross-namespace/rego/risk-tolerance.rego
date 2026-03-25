package signalprocessing

import rego.v1

# Appended by concurrent-cross-namespace scenario to extract risk_tolerance
# from namespace labels. Only fires when kubernaut.ai/team is absent so it
# does not conflict with the existing team/tier rules in policy.rego.
labels := {"risk_tolerance": [rt]} if {
	rt := input.namespace.labels["kubernaut.ai/risk-tolerance"]
	rt != ""
	not input.namespace.labels["kubernaut.ai/team"]
}
