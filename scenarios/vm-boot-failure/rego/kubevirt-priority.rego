package signalprocessing

import rego.v1

# KubeVirt / CNV signals: escalate to P1 regardless of environment.
# Matches both Gateway-ingested alerts (kubernetes_operator_part_of label)
# and AF-originated signals (severity_alert_name label).
priority := {"priority": "P1", "policy_name": "kubevirt-vm-failure"} if {
	_is_kubevirt_signal
}

_is_kubevirt_signal if {
	input.signal.labels.kubernetes_operator_part_of == "kubevirt"
}
_is_kubevirt_signal if {
	contains(input.signal.labels.severity_alert_name, "VirtualMachine")
}
