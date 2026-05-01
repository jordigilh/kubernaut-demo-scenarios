# Scenario: Operator Health Management (OLM)

**Status**: IN PROGRESS — scenario scripts and manifests implemented; end-to-end validation pending on live cluster.

## Overview

Demonstrates Kubernaut diagnosing and remediating OpenShift Operator Lifecycle Manager
(OLM) failures when a ClusterServiceVersion is deleted (for example during a flawed
namespace cleanup script). The etcd operator from the `community-operators` catalog
is installed with a manual InstallPlan; the CSV is deleted to drive `csv_succeeded`
to 0 and fire `OperatorCSVFailed`.

## ITIL Mapping

| Level | Task |
|-------|------|
| L2 | Availability management — Operator health |

## Signal

| Field | Value |
|-------|-------|
| Alert | `OperatorCSVFailed` |
| Source | Prometheus (`csv_succeeded` from kube-state-metrics) |
| Severity | high |

## Running

Requires an OpenShift cluster with OLM, `community-operators`, and platform monitoring.

```bash
./scenarios/operator-health/run.sh [--auto-approve|--interactive] [--no-validate]
./scenarios/operator-health/validate.sh [--auto-approve]
./scenarios/operator-health/cleanup.sh
```

## Remediation

Register `deploy/remediation-workflows/operator-health/operator-health.yaml` and the
`restore-operator-csv-job` workflow bundle. Expected action: `RestoreOperatorCSV`.

## Prerequisites

- OpenShift cluster with OLM enabled
- kube-state-metrics exposing OLM CSV metrics (`csv_succeeded`)
- Customer-defined remediation workflow registered in DataStorage
