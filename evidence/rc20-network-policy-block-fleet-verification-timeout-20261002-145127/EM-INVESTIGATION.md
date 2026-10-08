# EffectivenessMonitor `NaN` investigation

## Live evidence

- RR: `rr-9d7638a122e2-dd1813f9`
- EA: `ea-rr-9d7638a122e2-dd1813f9`
- The workflow removed `default-network-policy`; `traffic-gen` and both
  `web-frontend` pods were Running/Ready.
- Health assessment repeatedly returned score `1`.
- Alert assessment repeatedly returned score `1` and reported the alert resolved.
- Metrics assessment reported `1 of 4 metrics improved, average score NaN`.
- The audit payload contained:
  - `latency_p95_before_ms: null`, `latency_p95_after_ms: 4.75`
  - `throughput_before_rps: 0`, `throughput_after_rps: 1.448...`
  - finite CPU and memory values
  - no 5xx series for the error-rate query, so that fifth query was correctly
    treated as unavailable
- EffectivenessMonitor logs repeatedly reported:
  - `Metrics assessment complete ... score=NaN, queriesAvailable=4, queriesTotal=5`
  - `Failed to update EA status ... json: unsupported value: NaN`

## Code path

1. `internal/controller/effectivenessmonitor/assess_components.go:351` builds
   the `histogram_quantile(0.95, ...)` latency query.
2. `pkg/effectivenessmonitor/client/prometheus_http.go:232-237` parses a
   Prometheus value with `strconv.ParseFloat`. Go accepts the string `"NaN"`
   without an error, so the sample remains available.
3. `pkg/effectivenessmonitor/metrics/scorer.go:150-168` computes a relative
   improvement from that non-finite pre-value. The result remains `NaN`, and
   `Score` averages it into the overall metric score.
4. `internal/controller/effectivenessmonitor/reconcile_components.go:282-284`
   stores the non-finite score in EA status.
5. `internal/controller/effectivenessmonitor/reconcile_status.go:45-51`
   attempts the Kubernetes status update; JSON encoding rejects `NaN`, so the
   EA cannot finalize normally and eventually expires.

## Classification

This is an upstream EffectivenessMonitor robustness defect, not a Fleet
transport, scenario, or missing-5xx-data failure. Non-finite Prometheus
samples should be discarded (or otherwise treated as unavailable) before
metric comparison, and the scorer/status path should defensively prevent
non-finite scores from reaching Kubernetes API serialization.

The live source had no `math.IsNaN`/`math.IsInf` guard in the Prometheus parser,
metric query executor, or scorer. A focused upstream regression test should
cover a matrix value of `"NaN"` from `histogram_quantile` and assert that the
metric is unavailable or that the final score remains finite.
