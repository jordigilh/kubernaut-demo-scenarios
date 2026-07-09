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
./scenarios/build-failure/run.sh [--auto-approve|--interactive] [--no-validate] [--alert-only]
./scenarios/build-failure/validate.sh [--auto-approve]
./scenarios/build-failure/cleanup.sh
```

### `run.sh` flags

| Flag | Behavior | When to use |
|------|----------|-------------|
| *(no flag)* | Runs the full pipeline with auto-approval (default) | Automated regression testing |
| `--no-validate` | Injects fault only, skips pipeline polling | **Always use with kagenti** |
| `--interactive` | Runs the pipeline, pauses at AwaitingApproval for manual approval | Gateway flow with human-in-the-loop |
| `--auto-approve` | Runs the full pipeline, auto-approves remediation | Automated regression testing (explicit) |
| `--alert-only` | Deploys, injects fault, waits for alert to fire, then exits | AF/A2A demos |

## Remediation

Register `deploy/remediation-workflows/build-failure/build-failure.yaml` and the
`fix-build-source-job` workflow bundle. Expected action: `FixBuildSource`.

## Prerequisites

- OpenShift cluster with Builds / BuildConfigs
- Prometheus monitoring build metrics (`openshift_build_status_phase_total`)
- Customer-defined remediation workflow registered in DataStorage
