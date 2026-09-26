# Autoscaling release fixes

Branch: `feat/autoscaling` (baseline `9d24719`).

Current status and remaining production gates: [release readiness](../autoscaling-release-readiness.md).
This document records successive implementation and validation passes; earlier test counts and
integration results apply to the code at those passes.

## Decisions

- Keep managed traffic through nscale. Discover all healthy Consul endpoints per
  service, refresh the pool every two seconds, and select endpoints round-robin.
- Coalesce readiness by service and serialize count mutations by task group. Wake only a zero
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

## Main branch integration

The merge incorporates local `main` at `e8d5499` (WebSocket upgrade tunneling).
Successful upgrades transfer the existing local request guard, Redis request
lease, heartbeat, and completion metrics into the tunnel. Failed or rejected
handshakes retain response-body tracking. The upgrade helper takes the guard
only after a 101 response, so the caller can finish tracking other responses.
The existing public forwarding API remains available unchanged.

A real-Redis HTTP upgrade regression holds a tunnel open for 31 seconds,
verifies shared activity through a separate Redis client, exchanges bytes,
and checks cleanup on tunnel closure and a rejected upgrade. The original
bidirectional tunnel regression is retained.

Final merged validation passed: formatting, `cargo check --workspace`, strict
workspace Clippy, and `cargo nextest run --workspace --run-ignored all` against
isolated Redis (160 passed, none skipped). Shell syntax and diff checks passed.
The full Nomad/Consul/Traefik integration scripts were not rerun in that merge
pass; they were rerun during the subsequent follow-up below.

## HA fallback and sibling-service follow-up

Native latency/error samples are explicitly incomplete across proxy replicas.
They can still trigger scale-up, but cannot authorize reductions when cluster
metrics fail, return no observations, or are not configured. Complete cluster
signals still authorize reductions. The existing idle scale-to-zero policy and
activity guards remain independent.

Wake readiness and cached endpoints are keyed by group and service. A local
per-group mutex protects only the count check/mutation, alongside the existing
shared Redis job lease. It is released before service health polling. A failed
or missing endpoint invalidates only that service's readiness; whole-unit
scale-down still invalidates every service.

Regressions cover the original unequal-replica metric case, unavailable/empty
cluster observations, both latency and error targets, known local overload,
cluster recovery, and healthy siblings during failed health waits in both
cold and already-running groups. The fake orchestrator now retains counts per
job/group, matching actual Nomad behavior during sibling wake tests.

The updated workspace passes 163 tests with all isolated-Redis cases enabled,
including lease loss/renewal, cancellation, authenticated retries, and the
31-second WebSocket tunnel. Formatting, workspace check, and strict Clippy pass.

The final follow-up also passes all four disposable integration suites:

- `test-autoscaling-regressions.sh`: cold minimum, three real allocation IDs,
  restart/count preservation, shared streaming protection, load-driven scaling,
  and `scale_to_zero = false`.
- `test-autoscaling-prometheus.sh`: 759 successful load requests, histogram and
  positive-rate samples from both proxies, aggregate p95, scale-up within the
  cap, and idle scale-to-zero.
- `test-multigroup.sh`: independent wake and idle reduction, including alpha
  reaching zero while beta remains active.
- `test-acl.sh`: 23 assertions, including scoped token access, submission,
  HTTP/HTTPS routing, cold wake, idle reduction, and re-wake.

Temporary Redis and integration stacks were removed after validation.

## Registration replacement and failed-wake follow-up

Successful `/admin/jobs` submissions replace the complete service set for that
job, removing obsolete registrations and policies from Redis and optional etcd.
The shared job mutation lease covers submission and registry replacement. Redis
updates both indexes in one Lua operation; etcd updates its keys in one transaction.
Local readiness is invalidated for affected units. Other jobs remain registered.
Busy submissions return 409. Store failures after Nomad accepts a job still return
207 with registration failures; operators must retry after restoring the store,
because the three systems do not share a transaction.

Wake callers subscribe to the shared health result before acquiring the endpoint
refresh mutex. Both successful and failed wakes are coalesced, and later requests
can retry failures. A deadline bounds the entire request wake path and background
wake task, including refresh, group mutation, and Nomad semaphore queues.

Regressions exercise eight concurrent failing wakes, one shared health attempt,
retry, queued deadlines, and cancellation before a delayed count mutation. Real
Redis and etcd tests exercise service removal, policy replacement, unrelated-job
preservation, rejected/busy submissions, and recovery after cache eviction.
All 167 workspace tests pass with ignored infrastructure tests enabled; formatting,
workspace check, strict Clippy, shell syntax, and diff checks pass.

The updated `test-durable.sh` also passes against the full disposable stack:
renaming a submitted service removes its old Redis and etcd entries, and both
warm requests and cold wakes recover after Redis registry cache loss.

## 3.0.0 packaging follow-up

All nine Cargo packages and their lockfile entries, plus Helm chart version and appVersion,
now target 3.0.0. No third-party dependency versions changed. The chart uses Recreate for the
app Deployment and noeviction for bundled Redis, with a 256 MiB container limit around its
100 MB data budget. Existing custom Redis config must still be reviewed during migration.

Chart values now expose endpoint refresh, Prometheus URL/timeout, missing-job cleanup, and an
independent existing Secret for the admin token. Default renders omit optional Prometheus and
admin authentication. Configured renders preserve separate Nomad/Consul Secret references.
Migration and operator documentation reflect these defaults and values.

Validation passed for 3.0.0: formatting, workspace check, strict Clippy, and all 167 workspace
tests with isolated Redis/etcd enabled. Helm lint and semantic render checks passed for default,
configured two-replica, and zero-replica durable deployments, including their runtime TOML.
Documentation link, shell-example, and diff checks passed. No live Kubernetes upgrade or
release publishing was performed; the remaining release gates still apply.

## Operational boundaries

- Redis request tokens expire after 30 seconds without renewal. Application
  graceful shutdown and Nomad `shutdown_delay`/`kill_timeout` must cover supported
  requests. Network partitions, direct/manual termination, and newly admitted
  requests racing a reduction are not guaranteed lossless.
- No production deployment, production traffic replay, or prolonged soak has
  been performed as part of these fixes.
- Drain and replace older proxy replicas together: mixed versions do not all
  publish shared request tokens or use the new mutation coordination.
- No new production dependencies or pushes are included.
