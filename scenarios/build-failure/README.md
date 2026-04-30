# Scenario: Build Failure (BuildConfig / S2I)

**Status**: PLANNED — not yet implemented

## Overview

Demonstrates Kubernaut diagnosing OpenShift Build failures — BuildConfig
producing failed Builds due to source clone errors, S2I builder image issues,
build pod OOM, or push failures to the internal registry.

## ITIL Mapping

| Level | Task |
|-------|------|
| L2 | Availability management — CI/CD build pipeline remediation |

## Signal

| Field | Value |
|-------|-------|
| Alert | `OpenShiftBuildFailed` or custom alert on build failure rate |
| Source | Prometheus AlertManager |
| Severity | medium |

## Investigation

KA investigates via the K8s dynamic client:

- Describe the failed Build resource and its phase/status
- Review build pod logs for compilation errors, dependency failures, or OOM events
- Check the BuildConfig source (Git URL, ref, secret) for connectivity issues
- Verify the builder image (ImageStream tag) exists and is pullable
- Check if the internal registry is healthy and has sufficient storage
- Review resource limits on the build pod

## Remediation (customer-defined)

Possible workflow actions:
- Retry the Build (create new Build from BuildConfig)
- Increase build pod resource limits if OOM was the cause
- Fix source secret if Git clone failed due to auth
- Escalate to development team if the failure is a code/dependency issue

## Prerequisites

- OpenShift cluster with Builds/BuildConfigs
- Prometheus monitoring build metrics
- Customer-defined remediation workflow registered in DataStorage
