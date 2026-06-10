# Scenario: Route Misconfiguration

## Overview

Simulates a failed blue/green deployment on OpenShift where the Route is
switched to a new Service (`storefront-web-v2`) that does not exist. External
traffic immediately receives 503 errors. Kubernaut detects the
`RouteBackendUnavailable` alert, investigates the Route and available Services,
identifies the correct target, and patches the Route back.

## ITIL Mapping

| Level | Task |
|-------|------|
| L2 | Availability management — Route/Ingress remediation |

## Signal

| Field | Value |
|-------|-------|
| Alert | `RouteBackendUnavailable` |
| Source | Prometheus AlertManager |
| Severity | high |
| Namespace | `demo-store` |

The PrometheusRule fires when `haproxy_backend_up == 1` (backend registered) but
no `haproxy_server_up` entries exist for the Route — meaning HAProxy knows about
the Route but has zero healthy servers behind it.

## Prerequisites

- OpenShift cluster (Route API is OCP-specific)
- HAProxy router metrics scraped by Prometheus (`haproxy_backend_up`, `haproxy_server_up`)
- Kubernaut platform with `fix-route-target-v1` workflow seeded

## Fault Injection

The `inject-bad-route.sh` script patches the Route's `spec.to.name` from
`storefront-web` (healthy, 2 replicas) to `storefront-web-v2` (non-existent
Service). This simulates a blue/green switch where the new version was never
deployed.

```
Route storefront: spec.to.name = storefront-web    (healthy)
                             ↓ inject
Route storefront: spec.to.name = storefront-web-v2  (does not exist → 503)
```

## Investigation

KA investigates via the K8s dynamic client:

1. Describes the Route resource (`spec.host`, `spec.to`, `spec.tls`)
2. Verifies the target Service exists and has healthy Endpoints
3. Lists available Services in the namespace and checks which have Endpoints
4. Identifies that `storefront-web` has healthy Endpoints while `storefront-web-v2` does not exist
5. Selects `fix-route-target-v1` workflow (ActionType: `FixRouteTarget`)

## Remediation

| Field | Value |
|-------|-------|
| Workflow | `fix-route-target-v1` |
| ActionType | `FixRouteTarget` |
| Engine | Job |
| Bundle | `quay.io/kubernaut-cicd/test-workflows/fix-route-target-job` |

The remediation job:

1. **Validate** — Gets the current Route target, checks if it exists and has
   Endpoints. Enumerates all Services in the namespace and finds the first one
   with healthy Endpoints.
2. **Action** — Patches the Route `spec.to.name` to the correct Service.
3. **Verify** — Confirms the Route target was updated successfully.

## Validation Assertions

| Assertion | Check |
|-----------|-------|
| RR phase | `Completed` |
| RR outcome | `Remediated` |
| SP phase | `Completed` |
| AA phase | `Completed` |
| Workflow selection | Bundle contains `fix-route-target-job` |
| AA confidence | Present (non-empty) |
| WFE phase | `Completed` |
| Route restored | `spec.to.name == storefront-web` |
| Pod health | At least 1 Running pod in `demo-store` |

## Pipeline Flow

```
1. Deploy storefront-web (2 replicas) + Service + Route (edge TLS)
2. Baseline: 20s healthy traffic
3. Inject: patch Route → storefront-web-v2 (non-existent)
4. Alert: RouteBackendUnavailable fires (~30s)
5. Gateway → SP → AA: LLM investigates Route, Services, Endpoints
6. AA selects fix-route-target-v1 (FixRouteTarget)
7. WFE job: discovers storefront-web has healthy endpoints → patches Route
8. EA verifies Route target restored + pods healthy
```

## Running

```bash
./scenarios/route-misconfiguration/run.sh
```

## Cleanup

```bash
./scenarios/route-misconfiguration/cleanup.sh
```

Deletes the `demo-store` namespace, removes the PrometheusRule, restores the RO
stabilization window, and purges pipeline CRDs.
