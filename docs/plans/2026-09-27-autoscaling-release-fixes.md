# Autoscaling release fixes

Branch: `feat/autoscaling` (baseline `9d24719`).

## Decisions

- Keep managed traffic through nscale. Discover all healthy Consul endpoints per
  service, refresh the pool every two seconds, and select endpoints round-robin.
- Coalesce wake by task group while selecting ports by service. Wake only a zero
  count, using the enabled policy's minimum. Restart/discovery misses and stopped
  allocations must preserve a running group's desired count.
- Use the task-group scale unit consistently for activity and request tracking.
  Aggregate all service rates in a group; use the worst service latency/error
  signal. Reject inconsistent policies across services sharing a group.
- Preserve missing metrics as unknown so fallback providers can supply them.
  Prefer router counters over service counters to avoid counting traffic twice.
  Missing required observations block reductions. Reject `min_count = 0`.
- Share renewable, ownership-token Redis leases across wake, autoscaling, and
  idle scale-down, keyed by Nomad job because its modification index spans groups.
  Recheck the observed count and enforce the Nomad job index on the write.
- Track requests through response completion or cancellation, including streams.
  Store expiring request tokens in Redis so other proxies see active requests.
  Fail new admission with HTTP 503 if Redis is unavailable; fail closed for
  reductions and unforced purge when shared request state cannot be read.

Nomad's scale endpoint supports the index check described in its
[Jobs API](https://developer.hashicorp.com/nomad/api-docs/jobs#scale-task-group).
Index checking prevents overwriting an intervening job update; it is not a
distributed fencing token tied to Redis lease ownership.

## Initial verification

The focused Rust regressions cover count preservation, minimum cold wake,
round-robin refresh, independent service ports, group metrics, missing/zero
observations, stale writes, allocation-stop invalidation, and response-body
lifetimes. The workspace suite passed 143 tests.

Four opt-in tests in `crates/nscale-store/tests/coordination.rs` passed against
isolated Redis: ownership-safe release/renewal after expiry, shared request
visibility/crash expiry, renewal beyond the 30-second lease, and cancellation
after ownership loss.

`integration/test-autoscaling-regressions.sh` passed against a disposable
Nomad/Consul/Redis/Traefik stack with two proxies. It verifies real allocation IDs
in HTTP responses, cold wake to three replicas, traffic across those replicas,
proxy restart preservation, a 4-to-3 allocation change, cross-proxy streaming
protection against unforced purge, and metric-driven scale-up/down with
`scale_to_zero = false`.

`integration/test-autoscaling-prometheus.sh` passed: 759 successful HTTP
requests, scale-up within the configured cap, and idle descent through 3, 2, 1,
and 0. A live query for an absent service returned an empty vector. Local Nomad
also rejected an explicitly stale job index; the regression uses that observed
error response.

`integration/test-multigroup.sh` passed with the final group-policy changes:
both groups idled to zero, each woke independently, and alpha returned to zero
while beta continued serving traffic.

Initial checks passed: `cargo fmt --all`, `cargo check --workspace`,
`cargo clippy --workspace --all-targets -- -D warnings`,
`cargo nextest run --workspace` (143 passed; the four isolated-Redis tests are
ignored by default and passed separately), shell syntax checks, and
`git diff --check`. On this machine, Cargo used the installed Xcode SDK because
the default Command Line Tools SDK was incompatible with the linker.

## Review follow-up

The subsequent review reproduced four remaining defects. The follow-up fixes:

- Use explicit service identity for proxy lookup, including durable-store lookup
  and exact-match legacy cache recovery. Administrative job aliases stay intact.
- Preserve the next backend across endpoint refreshes, including reordered
  discovery responses and added/removed endpoints.
- Retain partial request-rate sums and worst known latency/error observations.
  Track completeness separately per signal: known overload can increase capacity,
  while gaps in configured signals block reductions. Failed sibling metric reads
  are treated as missing observations.
- Export request latency as Prometheus histogram buckets so the existing p95
  query can aggregate across proxy replicas.

Follow-up checks passed: formatting, workspace compilation, strict Clippy,
148 workspace tests, five isolated Redis tests, and shell syntax/diff checks.
The added Redis case verifies the service/job-name collision and legacy lookup
compatibility. Sparse-request rotation, changed pool membership, partial-metric
scale-up/down decisions, and the real exporter format have focused regressions.

The expanded Prometheus integration passed with two proxies and 759 successful
load-test requests. Both proxies exposed histogram buckets, the aggregate p95
query returned a value, and a separate live query verified positive request rates
from both instances in the same window. That last assertion is now also in the
script, with peer traffic paced across scrape intervals.

The updated multi-group HTTP integration also passed with the job ID deliberately
equal to the alpha service name and beta registered afterward. Alpha requests woke
only alpha, beta woke independently, and alpha returned to zero while beta stayed
active. Disposable integration containers were cleaned up after verification.

## Second review follow-up

Lease execution now awaits ownership-checked release on normal and error returns,
with Drop cleanup retained for cancellation. This prevents a completed group from
holding the job lease while its sibling is evaluated. A real-Redis controller
regression requires both sibling groups to be evaluated on every sweep.

Transport retries preserve request headers, URI, method, and HTTP version.
Only GET/HEAD requests with a known empty body are replayed. Regressions cover
an authenticated request timing out on the first attempt, header preservation,
nonempty GET rejection, lease completion/error handoff, and cancellation cleanup.

## Operational boundaries

- Redis request tokens expire after 30 seconds without renewal. Application
  graceful shutdown and Nomad `shutdown_delay`/`kill_timeout` must cover supported
  requests. Network partitions, direct/manual termination, and newly admitted
  requests racing a reduction are not guaranteed lossless.
- No production deployment, production traffic replay, prolonged soak, or
  ACL-enabled integration has been performed as part of these fixes.
- Drain and replace older proxy replicas together: mixed versions do not all
  publish shared request tokens or use the new mutation coordination.
- No new production dependencies or pushes are included.
