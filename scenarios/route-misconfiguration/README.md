# Scenario: Route/Ingress Misconfiguration

**Status**: PLANNED — not yet implemented

## Overview

Demonstrates Kubernaut diagnosing OpenShift Route or Ingress misconfigurations
that result in 503 Service Unavailable, 404 Not Found, or TLS termination
errors for external traffic.

## ITIL Mapping

| Level | Task |
|-------|------|
| L2 | Availability management — Route/Ingress remediation |

## Signal

| Field | Value |
|-------|-------|
| Alert | `HAProxyBackendDown` or custom alert on Route error rate |
| Source | Prometheus AlertManager |
| Severity | high |

## Investigation

KA investigates via the K8s dynamic client:

- Describe the Route resource (spec.host, spec.to, spec.tls)
- Verify the target Service exists and has healthy Endpoints
- Check if the Service selector matches running pods
- Review HAProxy router pod logs for backend connection errors
- Verify TLS certificate validity if TLS termination is configured
- Check for conflicting Routes on the same hostname

## Remediation (customer-defined)

Possible workflow actions:
- Patch Route to correct the target Service reference
- Recreate Endpoints by restarting the target Deployment
- Renew TLS certificate if expired
- Escalate to L2 if the issue is a router infrastructure problem

## Prerequisites

- OpenShift cluster with Routes configured
- Prometheus monitoring HAProxy router metrics
- Customer-defined remediation workflow registered in DataStorage
