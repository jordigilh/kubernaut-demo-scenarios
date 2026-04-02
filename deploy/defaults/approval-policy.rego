# AI Analysis Approval Policy
#
# Determines whether a remediation requires manual approval before execution.
# Production environments always require approval; non-production auto-approves.
#
# Deploy via Helm:
#   helm install kubernaut kubernaut/kubernaut \
#     --set-file aianalysis.policies.content=deploy/defaults/approval-policy.rego
#
# Input schema (from AI Analysis controller):
#   input.environment          string   — environment classification from SP
#   input.confidence           float    — LLM confidence score (0.0–1.0)
#   input.warnings             []string — LLM-raised warnings
#   input.failed_detections    []string — detection fields that failed
#   input.remediation_target   object   — {kind, name, namespace} identified by LLM
#   input.target_resource      object   — {kind, name, namespace} from the alert

package aianalysis.approval

import rego.v1

default require_approval := false
default reason := "Auto-approved"

# ========== Approval Rules ==========
# All environment comparisons use lower() to handle PascalCase values
# from SignalProcessing's LabelDetector (e.g. "Production" → "production").

require_approval if { lower(input.environment) == "production" }

require_approval if {
    input.remediation_target
    input.remediation_target.kind == "StatefulSet"
}

require_approval if {
    input.remediation_target
    input.remediation_target.kind == "Node"
}

require_approval if {
    not input.remediation_target
}

require_approval if {
    count(input.warnings) > 0
}

# ========== Risk Factor Scoring ==========
# The highest-scoring factor determines the human-readable reason.

risk_factors contains {"score": 90, "reason": "Missing remediation target"} if {
    not input.remediation_target
}

risk_factors contains {"score": 80, "reason": "Sensitive resource kind requires manual approval"} if {
    input.remediation_target
    input.remediation_target.kind == "StatefulSet"
}

risk_factors contains {"score": 80, "reason": "Sensitive resource kind requires manual approval"} if {
    input.remediation_target
    input.remediation_target.kind == "Node"
}

risk_factors contains {"score": 75, "reason": "LLM raised warnings — human review recommended"} if {
    count(input.warnings) > 0
}

risk_factors contains {"score": 70, "reason": "Production environment requires manual approval"} if {
    lower(input.environment) == "production"
}

all_scores contains f.score if { some f in risk_factors }
max_risk_score := max(all_scores) if { count(all_scores) > 0 }
reason := f.reason if { some f in risk_factors; f.score == max_risk_score }
