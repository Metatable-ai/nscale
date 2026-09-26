# Performance configuration guide

This guide explains how to configure `nscale` for reliable scale-to-zero behavior under real traffic.

It focuses on the settings and surrounding infrastructure that most strongly affect wake latency, long-running request safety, scale-down correctness, and steady-state proxy behavior. It is especially useful for mixed fleets where some services are lightweight and others can hold requests open for tens of seconds.

The recommended values in this document are a practical baseline, not hard requirements. They are intended to help operators choose reasonable starting points and understand the trade-offs behind each knob.

## What matters most

If you only remember a few things, remember these:

1. **All traffic for managed services should pass through `nscale`** on both the cold path and the warm path.
2. **Ingress/client timeouts must cover wake time, backend work, and any permitted retries**; the backend attempt has its own timeout.
3. **Shared Redis request leases protect long-running requests** while their heartbeats continue.
4. **The Traefik traffic probe should be enabled** if you want safe, aggressive scale-down.
5. **Fast scale-down sweeps only work when the guardrails are present**.

## How configuration is loaded

`nscale` loads configuration in this order:

1. built-in defaults
2. `config/default.toml`
3. environment variables prefixed with `NSCALE_`

Nested environment variables use **double underscores**.

Example:

- `NSCALE_NOMAD__ADDR`
- `NSCALE_CONSUL__TOKEN`
- `NSCALE_SCALING__IDLE_TIMEOUT_SECS`

Do not use single underscores for nested fields. The loader uses Figment with `.split("__")`.

This matters operationally because a setting in `config/default.toml` can be silently overridden by an environment variable in Kubernetes or Compose. When debugging surprising behavior, always check the effective environment first.

## Recommended baseline profile

The repository defaults are intentionally conservative for local development. For a more responsive mixed-fleet deployment, the following profile is a strong baseline.

### Defaults vs recommended

| Setting | Default | Recommended |
|---|---:|---:|
| `scaling.idle_timeout_secs` | 300 | 45 |
| `scaling.scale_down_interval_secs` | 30 | 5 |
| `scaling.min_scale_down_age_secs` | 120 | Currently unused; do not rely on this as a guard |
| `proxy.request_timeout_secs` | 30 | 90 |
| `traefik` | not set | enabled |

### Full recommended profile

```toml
[default]
listen_addr = "0.0.0.0:8080"
admin_addr = "0.0.0.0:9090"

[default.nomad]
addr = "http://host.docker.internal:4646"
concurrency = 50

[default.consul]
addr = "http://host.docker.internal:8500"

[default.redis]
url = "redis://redis:6379"

[default.scaling]
idle_timeout_secs = 45
wake_timeout_secs = 60
scale_down_interval_secs = 5

[default.proxy]
request_timeout_secs = 90

[default.traefik]
metrics_url = "http://traefik:8082"
provider = "consulcatalog"
```

Use this as a starting point when you want:

- fast idle detection
- safe protection for long-running requests
- bounded cold-start latency
- aggressive but controlled scale-down behavior

## What each setting does

| Area | Setting | Recommended value | Why |
|---|---|---:|---|
| Nomad | `nomad.concurrency` | `50` | Sufficient for most fleets with up to 50 concurrent services waking simultaneously. |
| Scaling | `scaling.idle_timeout_secs` | `45` | Controls idle eligibility; request heartbeats are capped at five seconds. |
| Scaling | `scaling.wake_timeout_secs` | `60` | Bounds one wake attempt, including queue time, Nomad work, and Consul readiness. |
| Scaling | `scaling.scale_down_interval_secs` | `5` | Keeps the controller reactive under frequent wake/sleep cycles. |
| Proxy | `proxy.request_timeout_secs` | `90` | Bounds one ordinary HTTP backend attempt after wake; size this for backend work and response streaming. |
| Prometheus | `prometheus.url` | optional | Queries Prometheus before the direct Traefik and nscale-native fallback providers when configured. |
| Prometheus | `prometheus.timeout_secs` | `5` | Bounds Prometheus query latency before falling back to direct providers. |
| Traefik | `traefik.metrics_url` | enabled | Enables the traffic probe, which prevents scale-down when Traefik is still serving requests to a healthy service. |
| Traefik | `traefik.provider` | `consulcatalog` | Must match the provider label used in Traefik metrics and service routing. |

## Key tuning rules

### Keep all traffic flowing through `nscale`

For stable in-flight protection, both the cold path and warm path must route through `nscale`.

Use Nomad service tags like this:

```hcl
tags = [
  "traefik.enable=true",
  "traefik.http.routers.my-service.rule=Host(`my-service.localhost`)",
  "traefik.http.routers.my-service.entryPoints=http",
  "traefik.http.routers.my-service.service=s2z-nscale@file",
]
```

Do **not** try to override `loadBalancer.servers[0].url` through ConsulCatalog tags. Traefik populates those servers automatically from Consul endpoints.

Why this matters:

- `nscale` can only protect in-flight requests it actually sees
- the scale-down controller is safer when warm traffic remains visible to `nscale`
- routing consistency prevents split-brain behavior between cold and warm service paths

### Budget wake and backend work separately

`scaling.wake_timeout_secs` bounds a call to the wake coordinator, including time queued behind
endpoint refresh, group mutation, and Nomad concurrency limits. Concurrent requests for one
service share success or failure; later requests can retry. Sibling services have separate
readiness waits, while count changes are coordinated per group and Nomad job.

`proxy.request_timeout_secs` configures the ordinary HTTP backend client after wake. It is not an
end-to-end timeout for the incoming request. Budget the ingress/client deadline for wake plus
backend work and retry overhead. For example, a 60-second wake and 90-second backend attempt can
consume 150 seconds before retry overhead. Only empty-body GET/HEAD requests are replayable.
WebSocket tunnels have separate lifetimes; do not treat this HTTP timeout as a tunnel deadline.

### Understand the heartbeat and lease budget

Request heartbeat cadence is `idle_timeout_secs / 3`, clamped to **100 ms–5 s**. With a 45-second
idle timeout, a long-running request refreshes activity and its shared lease every five seconds.
Each request token expires after **30 seconds without renewal**. Tracking remains active until
HTTP response-body completion, disconnect, or WebSocket tunnel closure.

All proxy replicas must use the same Redis store. New admission fails with `503` if Redis cannot
record the request token. Reductions and unforced purge are blocked when shared request state
cannot be read. Lease expiry bounds crash cleanup; it does not make network partitions or direct
allocation termination lossless. Configure application graceful shutdown and Nomad drain/kill
settings for supported request durations.

Changing `idle_timeout_secs` affects idle eligibility and, below the five-second cap, heartbeat
frequency. It does not change the 30-second request-token lifetime.

### Enable the Traefik traffic probe

Set both of these:

- `traefik.metrics_url`
- `traefik.provider`

Without the probe, `nscale` must rely only on its own in-flight tracking. That is not enough for the warm-path routing case where Traefik can continue sending healthy traffic while the service looks idle from Redis alone.

`nscale` clears the traffic-probe baseline after successful scale-down so stale counters do not poison the next wake cycle.

### Configure autoscaling per job, not globally

Autoscaling policies live on `JobRegistration` records submitted through `/admin/jobs`,
`/admin/registry`, or `/admin/registry/sync`. There is no global autoscaling block in
`config/default.toml`; jobs without an `autoscaling` object keep the existing scale-to-zero-only
behavior.

For autoscaled jobs, Prometheus is optional. When configured, nscale queries Prometheus before the
direct Traefik and nscale-native fallback providers. Missing required observations block reductions. Replica-local latency/error observations may
trigger scale-up, but cannot authorize reductions, even in a single-proxy deployment. Configure
Prometheus to aggregate all proxy replicas if latency/error policies need to scale down. The autoscaler only manages running jobs between each
job's `min_count` and `max_count`; wake-on-request and idle scale-down still own the transition to
and from zero. Set `scale_to_zero = false` in a job policy when a service should stay at or above
`min_count` instead of becoming dormant.

Use per-job `cooldown_secs` and `decision_window_secs` when a service needs faster or slower
autoscaling decisions than the defaults. These are policy fields on the registration payload, not
global config-file settings.

For operating many autoscaled jobs, use `GET /admin/autoscaling` to inspect which registrations have
autoscaling policies and what Nomad count nscale currently sees. Use `/metrics` to alert on
`nscale_autoscale_skips_total` reasons such as `metrics-error`, `cooldown`, and `dormant`, and on
`nscale_autoscale_decisions_total` to confirm scale-up and scale-down decisions are actually being
applied.

### Use fast scale-down sweeps only when the guardrails are enabled

A `scale_down_interval_secs` of `5` works well **because** `nscale` includes:

- in-flight request guards
- heartbeat refreshes during long requests
- Traefik metrics probing
- scale-down deferral when Nomad reports an active deployment
- traffic baseline clearing after successful scale-down

A slower sweep is not a replacement for these protections. Confirm shared Redis request tracking,
routing, and metrics in the target environment before enabling aggressive reductions.

### Keep Nomad concurrency high enough to absorb fan-out wakes

`nomad.concurrency = 50` is sufficient for most fleets and prevents the wake coordinator from becoming the bottleneck.

Lower it if:

- your Nomad control plane is CPU-starved
- your Consul convergence is slow under burst wake-ups
- you see control-plane errors rather than application errors

Raise it only after verifying Nomad and Consul can keep up.

## External system configuration

### Traefik

Recommended characteristics:

- enable Prometheus metrics on a dedicated entrypoint such as `:8082`
- enable the file provider for the fallback `s2z-nscale` service
- enable ConsulCatalog with `strictChecks` configured as a list
- set `refreshInterval: 1s` when you want fast route convergence during wake cycles
- set `responseHeaderTimeout` high enough to cover wake + backend work

Example:

```yaml
providers:
  file:
    filename: /etc/traefik/dynamic.yml
    watch: true
  consulCatalog:
    endpoint:
      address: consul:8500
      scheme: http
    exposedByDefault: false
    watch: true
    refreshInterval: 1s
    defaultRule: "Host(`{{ .Name }}.localhost`)"
    strictChecks:
      - "passing"
      - "warning"

serversTransport:
  forwardingTimeouts:
    dialTimeout: 1s
    responseHeaderTimeout: 150s
```

Notes:

- `strictChecks` must be a YAML list, not a boolean.
- If your workloads can exceed 30 seconds of request duration, increase `responseHeaderTimeout` to match the larger request budget.

Operationally, Traefik is not just the front door. It is also part of the safety system because `nscale` relies on consistent routing and, optionally, Traefik request metrics to make scale-down decisions.

### Prometheus

Prometheus is optional. When configured, it should scrape:

```text
Traefik /metrics
nscale /metrics
```

Configure the API endpoint with:

```text
NSCALE_PROMETHEUS__URL=http://prometheus:9090
NSCALE_PROMETHEUS__TIMEOUT_SECS=5
```

The equivalent TOML is:

```toml
[default.prometheus]
url = "http://prometheus:9090"
timeout_secs = 5
```

When Prometheus is configured, nscale queries it before direct Traefik and nscale-native fallback
providers. Scrape every proxy replica: latency uses aggregate histogram buckets, and error rate
uses aggregate request counters. Empty or unavailable observations remain unknown. Local overload
can still increase capacity; incomplete required signals cannot authorize reductions.

The repository includes an opt-in Prometheus integration test:

```bash
cd integration
./test-autoscaling-prometheus.sh
```

The test uses `docker-compose.prometheus.yml` to add Prometheus to the normal integration stack,
sets `NSCALE_PROMETHEUS__URL=http://prometheus:9090`, verifies Prometheus has Traefik and nscale
samples, and checks that a request-rate autoscaled job scales up within `max_count` and returns to
zero.

### Nomad

Recommended characteristics:

- use a stable API address with low RTT from `nscale`
- keep the target task group name stable across jobs
- ensure scale permissions exist when ACLs are enabled
- for slow jobs, provision enough CPU and memory that cold starts do not dominate the wake window

`nscale` handles Nomad's `scaling blocked due to active deployment` response explicitly during both scale-up and scale-down. That makes the system tolerant of rolling deploys.

Nomad behavior has a direct impact on perceived wake quality. Slow scheduling, deployment contention, or inconsistent task-group naming will show up as wake delays or spurious scale-down problems.

### Consul

Recommended characteristics:

- keep service health checks lightweight and frequent
- use `interval = "2s"` and `timeout = "1s"` as a good starting point for simple HTTP jobs
- keep Consul close to both Nomad and `nscale` so healthy endpoints appear quickly after a wake

Consul effectively determines when a waking service is considered ready for traffic. If health convergence is slow, wake latency grows even when Nomad scaling itself is fast.

### Redis

Redis is on the hot path for:

- activity timestamps
- job registry
- renewable job-mutation and controller leases
- shared active-request tokens and autoscaling cooldowns

Use `maxmemory-policy noeviction` and capacity monitoring: eviction of active request or mutation
keys can remove coordination without a connection error. The 3.0.0 chart uses `noeviction` by
default; inherited Helm values or external Redis may still need this change. See the [migration guide](./migration-autoscaling.md) before changing Redis configuration
or restarting it.

For best performance:

- keep Redis in the same low-latency network zone as `nscale`
- avoid overloaded shared Redis instances
- watch for latency spikes before tuning `idle_timeout_secs` downward

Redis performance affects both correctness and responsiveness. Activity timestamps, registry lookups, and the distributed scale-down lock are all sensitive to latency spikes.

### Kubernetes deployment profile

For a small-to-medium single-instance deployment, the following resource profile is a good starting point:

- `requests.cpu = 100m`
- `requests.memory = 128Mi`
- `limits.cpu = 500m`
- `limits.memory = 512Mi`
- readiness on `/readyz`
- liveness on `/healthz`

Adjust upward if you expect:

- higher sustained RPS through the proxy
- more simultaneous wake operations
- heavier tracing or debug logging
- multiple noisy neighbors on the same node

## Reserved settings

The following settings are accepted by the configuration loader but do not yet affect runtime behavior:

- `scaling.min_scale_down_age_secs`
- `proxy.request_buffer_size`
- `registry.etcd_watch_backoff_secs`

Do not assume changing them will affect performance until a future release wires them into the active code path.

## Durable registry mode

If you enable the etcd-backed durable registry, treat it as a correctness and resilience feature,
not a latency optimization.

Key points:

- Redis remains the hot cache for request-path lookups and scale-down coordination.
- etcd stores the durable registration source of truth.
- a Redis cache miss may incur a slightly slower first lookup because `nscale` reads through to etcd
  and then repopulates Redis.
- multi-replica deployments should keep durable registry mode enabled so each replica can recover
  the shared cache from the same source of truth.

The durable registry settings are configured under `[default.registry]` and are described in more
detail in [`durable-registry.md`](./durable-registry.md).

## Suggested environment variables

```bash
NSCALE_NOMAD__ADDR=http://host.docker.internal:4646
NSCALE_CONSUL__ADDR=http://host.docker.internal:8500
NSCALE_REDIS__URL=redis://redis:6379
NSCALE_NOMAD__CONCURRENCY=50
NSCALE_SCALING__IDLE_TIMEOUT_SECS=45
NSCALE_SCALING__WAKE_TIMEOUT_SECS=60
NSCALE_SCALING__SCALE_DOWN_INTERVAL_SECS=5
NSCALE_PROXY__REQUEST_TIMEOUT_SECS=90
NSCALE_TRAEFIK__METRICS_URL=http://traefik:8082
NSCALE_TRAEFIK__PROVIDER=consulcatalog
```

## Practical tuning workflow

When tuning a new environment, work in this order:

1. make sure all traffic routes through `nscale`
2. set a realistic proxy timeout for your slowest expected request
3. enable Traefik metrics probing
4. start with moderate scale-down aggression
5. observe wake latency, idle behavior, and long-request safety
6. only then tighten timeouts and intervals further

Before going to production, verify these scenarios work correctly:

- Warm-path traffic is proxied without errors
- Multiple services can wake concurrently without timeouts
- Long-running requests survive beyond the idle timeout window
- Services scale down after going idle and wake again on new traffic

## Tuning for common workload types

### Fast lightweight APIs (< 1s response time)

For services that respond quickly and should scale down aggressively:

```toml
[default.scaling]
idle_timeout_secs = 30
scale_down_interval_secs = 5

[default.proxy]
request_timeout_secs = 70
```

The short idle timeout makes services eligible for scale-down sooner. The 70-second proxy timeout
applies to a backend attempt; a 60-second cold wake can add to that. Choose a smaller backend
budget if appropriate and allow for both phases in ingress/client deadlines.

### Slow batch or processing services (10–60s response time)

For services that hold connections open for extended work:

```toml
[default.scaling]
idle_timeout_secs = 60
scale_down_interval_secs = 10

[default.proxy]
request_timeout_secs = 120
```

Heartbeats remain capped at five seconds. The 120-second proxy timeout covers backend work and
HTTP response streaming after wake; a 60-second cold wake can add to that. The slower sweep
interval reduces check frequency.

### Mixed fleet (fast and slow services together)

Use the recommended baseline profile. It is calibrated for the worst-case service (slow) while remaining responsive enough for fast services.

## Rollout verification

Follow the [autoscaling release gates](./autoscaling-release-readiness.md) before production.
Drain and replace older proxies together: they do not publish the shared request tokens used by
this branch. Validate real workload durations, metrics coverage, and rollback in staging; the
local integration runs do not establish those production properties.
