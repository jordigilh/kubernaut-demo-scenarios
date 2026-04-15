# Unified SignalProcessing Classification Policy
#
# Deploy via Helm:
#   helm install kubernaut kubernaut/kubernaut \
#     --set-file signalprocessing.policies.content=deploy/defaults/signalprocessing-policy.rego
#
# Input schema (type-safe from Go):
#   input.namespace.name         string
#   input.namespace.labels       map[string]string
#   input.namespace.annotations  map[string]string
#   input.signal.severity        string
#   input.signal.type            string
#   input.signal.source          string
#   input.signal.labels          map[string]string
#   input.workload.kind          string
#   input.workload.name          string
#   input.workload.labels        map[string]string
#   input.workload.annotations   map[string]string

package signalprocessing

import rego.v1

# ========== Environment Classification (BR-SP-051) ==========
# Reads the kubernaut.ai/environment namespace label, falling back to
# well-known namespace names when no label is present.
# Output values are PascalCase to match the SP CRD enum:
#   "Production", "Staging", "Development", "Test", "Unknown"
# Input comparisons use lower() for case-insensitive matching.

default environment := {"environment": "Unknown", "source": "default"}

environment := {"environment": "Production", "source": "namespace-labels"} if {
    env := input.namespace.labels["kubernaut.ai/environment"]
    lower(env) == "production"
}
environment := {"environment": "Staging", "source": "namespace-labels"} if {
    env := input.namespace.labels["kubernaut.ai/environment"]
    lower(env) == "staging"
}
environment := {"environment": "Development", "source": "namespace-labels"} if {
    env := input.namespace.labels["kubernaut.ai/environment"]
    lower(env) == "development"
}
environment := {"environment": "Test", "source": "namespace-labels"} if {
    env := input.namespace.labels["kubernaut.ai/environment"]
    lower(env) == "test"
}
environment := {"environment": "Production", "source": "namespace-name"} if {
    not input.namespace.labels["kubernaut.ai/environment"]
    lower(input.namespace.name) == "production"
}
environment := {"environment": "Production", "source": "namespace-name"} if {
    not input.namespace.labels["kubernaut.ai/environment"]
    lower(input.namespace.name) == "prod"
}
environment := {"environment": "Staging", "source": "namespace-name"} if {
    not input.namespace.labels["kubernaut.ai/environment"]
    lower(input.namespace.name) == "staging"
}
environment := {"environment": "Development", "source": "namespace-name"} if {
    not input.namespace.labels["kubernaut.ai/environment"]
    lower(input.namespace.name) == "development"
}
environment := {"environment": "Development", "source": "namespace-name"} if {
    not input.namespace.labels["kubernaut.ai/environment"]
    lower(input.namespace.name) == "dev"
}

# ========== Severity Normalization (BR-SP-105) ==========
# Maps Prometheus/Alertmanager severity labels to kubernaut-standard values.
# Extend the else-chain to support additional monitoring tools.

default severity := "unknown"

severity := "critical" if { lower(input.signal.severity) == "critical" }
severity := "high"     if { lower(input.signal.severity) == "high" }
severity := "medium"   if { lower(input.signal.severity) == "medium" }
severity := "medium"   if { lower(input.signal.severity) == "warning" }
severity := "low"      if { lower(input.signal.severity) == "low" }
severity := "low"      if { lower(input.signal.severity) == "info" }

# ========== Priority Assignment (BR-SP-070) ==========
# Combines environment and severity to assign a priority bucket (P0–P3).

default priority := {"priority": "P3", "policy_name": "default"}

priority := {"priority": "P0", "policy_name": "production-critical"} if {
    environment.environment == "Production"
    severity == "critical"
}
priority := {"priority": "P1", "policy_name": "production-high"} if {
    environment.environment == "Production"
    severity == "high"
}
priority := {"priority": "P1", "policy_name": "staging-critical"} if {
    environment.environment == "Staging"
    severity == "critical"
}
priority := {"priority": "P2", "policy_name": "staging-any"} if {
    environment.environment == "Staging"
    severity != "critical"
}

# ========== Custom Labels (BR-SP-102) ==========
# Extracts operator-defined labels from namespace metadata for
# workflow-context matching (team, tier).

default labels := {}

labels := {"team": [team], "tier": [tier]} if {
    team := input.namespace.labels["kubernaut.ai/team"]
    team != ""
    tier := input.namespace.labels["kubernaut.ai/tier"]
    tier != ""
}

labels := {"team": [team]} if {
    team := input.namespace.labels["kubernaut.ai/team"]
    team != ""
    not input.namespace.labels["kubernaut.ai/tier"]
}
