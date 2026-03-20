package aianalysis.approval

import rego.v1

default require_approval := false
default reason := "Auto-approved"

# Helpers
is_production if { input.environment == "production" }
has_warnings if { count(input.warnings) > 0 }

llm_warns_no_remediation if {
    some w in input.warnings
    contains(w, "no remediation warranted")
}

# Production environments always require approval (default behavior)
require_approval if { is_production }

# LLM explicitly signals "no remediation warranted" — force human review
# even in staging/dev where the default policy auto-approves (#60).
require_approval if { llm_warns_no_remediation }

# Catch-all: any other LLM warning also triggers review
require_approval if { has_warnings }

# Scored risk factors — highest score wins the reason string
risk_factors contains {"score": 80, "reason": "LLM warning: no remediation warranted"} if {
    llm_warns_no_remediation
}
risk_factors contains {"score": 75, "reason": "LLM raised warnings — human review recommended"} if {
    has_warnings
    not llm_warns_no_remediation
}
risk_factors contains {"score": 70, "reason": "Data quality warnings in production environment"} if {
    is_production
    has_warnings
}
risk_factors contains {"score": 60, "reason": "Data quality issues detected in production environment"} if {
    is_production
    count(input.failed_detections) > 0
}
risk_factors contains {"score": 40, "reason": "Production environment requires manual approval"} if {
    is_production
}

all_scores contains f.score if { some f in risk_factors }
max_risk_score := max(all_scores) if { count(all_scores) > 0 }
reason := f.reason if { some f in risk_factors; f.score == max_risk_score }
