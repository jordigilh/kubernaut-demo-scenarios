# Scenario: Build Failure (BuildConfig / S2I)

**Status**: IN PROGRESS — scenario scripts and manifests implemented; end-to-end validation pending on live cluster.

## Overview

Demonstrates Kubernaut diagnosing OpenShift build failures when a BuildConfig's Git
source URI is wrong after a migration (for example `fatal: repository not found`).
The scenario uses S2I with the `httpd:2.4-ubi9` builder, a known-good baseline build
against `https://github.com/sclorg/httpd-ex.git`, then patches the BuildConfig to a
non-existent repository and starts a failing build. The `BuildFailureRate` alert
fires from `openshift_build_status_phase_total`.

## ITIL Mapping

| Level | Task |
|-------|------|
| L2 | Availability management — CI/CD pipeline remediation |

## Signal

| Field | Value |
|-------|-------|
| Alert | `BuildFailureRate` |
| Source | Prometheus / Alertmanager |
| Severity | high |

## Running

Requires OpenShift with Builds, user workload monitoring (or equivalent scraping of
`openshift_build_status_phase_total`), and the `httpd:2.4-ubi9` ImageStreamTag in
`openshift`. The `oc` CLI is required (`start-build`).

```bash
./scenarios/build-failure/run.sh [--auto-approve|--interactive] [--no-validate]
./scenarios/build-failure/validate.sh [--auto-approve]
./scenarios/build-failure/cleanup.sh
```

## Remediation

Register `deploy/remediation-workflows/build-failure/build-failure.yaml` and the
`fix-build-source-job` workflow bundle. Expected action: `FixBuildSource`.

## Prerequisites

- OpenShift cluster with Builds / BuildConfigs
- Prometheus monitoring build metrics (`openshift_build_status_phase_total`)
- Customer-defined remediation workflow registered in DataStorage
