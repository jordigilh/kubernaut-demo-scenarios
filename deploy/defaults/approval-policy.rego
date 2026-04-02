# AI Analysis Approval Policy
#
# Determines whether a remediation requires manual approval before execution.
# High-confidence production analyses auto-approve; low-confidence require approval.
# Sensitive resources (Node, StatefulSet) always require approval.
#
# Deploy via Helm:
#   helm install kubernaut kubernaut/kubernaut \
#     --set-file aianalysis.policies.content=deploy/defaults/approval-policy.rego
#
# Input schema (from AI Analysis controller):
#   input.environment            string   — environment classification from SP
#   input.confidence             float    — LLM confidence score (0.0–1.0)
#   input.confidence_threshold   float    — optional operator override (default 0.8)
#   input.warnings               []string — LLM-raised warnings
#   input.failed_detections      []string — detection fields that failed
#   input.remediation_target     object   — {kind, name, namespace} identified by LLM
#   input.target_resource        object   — {kind, name, namespace} from the alert

package aianalysis.approval

import rego.v1

default require_approval := false
default reason := "Auto-approved"

# Configurable confidence threshold — operators can override via input.confidence_threshold.
# Analyses below this threshold always require human approval.
default confidence_threshold := 0.8

confidence_threshold := input.confidence_threshold if {
    input.confidence_threshold
}

# ========== Helper Functions ==========

is_high_confidence if {
    input.confidence >= confidence_threshold
}

is_production if {
    lower(input.environment) == "production"
}

is_sensitive_resource if {
    input.remediation_target
    input.remediation_target.kind == "Node"
}

is_sensitive_resource if {
    input.remediation_target
    input.remediation_target.kind == "StatefulSet"
}

# ========== Approval Rules ==========
# All environment comparisons use lower() to handle PascalCase values
# from SignalProcessing's LabelDetector (e.g. "Production" → "production").

# Sensitive resources always require approval regardless of confidence.
require_approval if { is_sensitive_resource }

# Missing remediation target — cannot determine what to remediate.
require_approval if { not input.remediation_target }

# LLM warnings warrant human review.
require_approval if { count(input.warnings) > 0 }

# Production with low confidence requires approval.
# High-confidence production analyses auto-approve (unless a rule above fires).
require_approval if {
    is_production
    not is_high_confidence
}

# ========== Risk Factor Scoring ==========
# The highest-scoring factor determines the human-readable reason.

risk_factors contains {"score": 90, "reason": "Missing remediation target"} if {
    not input.remediation_target
}

risk_factors contains {"score": 80, "reason": "Sensitive resource kind requires manual approval"} if {
    is_sensitive_resource
}

risk_factors contains {"score": 75, "reason": "LLM raised warnings — human review recommended"} if {
    count(input.warnings) > 0
}

risk_factors contains {"score": 70, "reason": "Production environment requires manual approval"} if {
    is_production
    not is_high_confidence
}

all_scores contains f.score if { some f in risk_factors }
max_risk_score := max(all_scores) if { count(all_scores) > 0 }
reason := f.reason if { some f in risk_factors; f.score == max_risk_score }
