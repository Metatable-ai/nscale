# Performance configuration guide

This guide explains how to configure `nscale` for reliable scale-to-zero behavior under real traffic.

It focuses on the settings and surrounding infrastructure that most strongly affect wake latency, long-running request safety, scale-down correctness, and steady-state proxy behavior. It is especially useful for mixed fleets where some services are lightweight and others can hold requests open for tens of seconds.

The recommended values in this document are a practical baseline, not hard requirements. They are intended to help operators choose reasonable starting points and understand the trade-offs behind each knob.

## What matters most

If you only remember a few things, remember these:

1. **All traffic for managed services should pass through `nscale`** on both the cold path and the warm path.
2. **Proxy timeout must cover both wake time and backend work time**.
3. **Idle timeout is also the heartbeat budget** for long-running requests.
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
| `scaling.min_scale_down_age_secs` | 120 | 30 |
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
| Scaling | `scaling.idle_timeout_secs` | `45` | Aggressive enough for fast scale-down while still allowing heartbeat refreshes every 15 seconds. |
| Scaling | `scaling.wake_timeout_secs` | `60` | Gives Nomad + Consul enough time to recover from cold starts without leaving requests hanging indefinitely. |
| Scaling | `scaling.scale_down_interval_secs` | `5` | Keeps the controller reactive under frequent wake/sleep cycles. |
| Proxy | `proxy.request_timeout_secs` | `90` | Covers up to 60 seconds of wake latency plus up to 30 seconds of backend work. |
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

### Align proxy timeout with wake budget and slow work

A good rule is:

$$
\text{proxy.request\\_timeout\\_secs} \ge \text{wake\\_timeout\\_secs} + \text{max backend request time}
$$

For the recommended baseline:

$$
90 = 60 + 30
$$

That is why a larger request timeout is appropriate for workloads with non-trivial cold-start and request duration.

If your workloads can hold a request open longer than 30 seconds, raise `proxy.request_timeout_secs` accordingly.

### Treat `idle_timeout_secs` as a heartbeat budget

`nscale` derives its heartbeat interval from:

$$
\text{heartbeat interval} = \frac{\text{idle\\_timeout\\_secs}}{3}
$$

With `idle_timeout_secs = 45`, heartbeats fire every 15 seconds during long-running proxied requests.

That is short enough to keep 10–30 second requests alive without making Redis writes excessively chatty.

If you lower `idle_timeout_secs`, you increase write frequency and make the system more sensitive to jitter. If you raise it too far, you reduce scale-to-zero aggressiveness.

In practice, `idle_timeout_secs` controls more than just scale-down speed:

- it influences how quickly a quiet service becomes eligible for scale-down
- it determines how often long-running requests refresh activity
- it changes how sensitive the system is to Redis latency and scheduling jitter

### Enable the Traefik traffic probe

Set both of these:

- `traefik.metrics_url`
- `traefik.provider`

Without the probe, `nscale` must rely only on its own in-flight tracking. That is not enough for the warm-path routing case where Traefik can continue sending healthy traffic while the service looks idle from Redis alone.

`nscale` clears the traffic-probe baseline after successful scale-down so stale counters do not poison the next wake cycle.

### Use fast scale-down sweeps only when the guardrails are enabled

A `scale_down_interval_secs` of `5` works well **because** `nscale` includes:

- in-flight request guards
- heartbeat refreshes during long requests
- Traefik metrics probing
- scale-down deferral when Nomad reports an active deployment
- traffic baseline clearing after successful scale-down

If any of those protections are disabled or unavailable in your environment, increase the sweep interval to compensate.

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
    responseHeaderTimeout: 60s
```

Notes:

- `strictChecks` must be a YAML list, not a boolean.
- If your workloads can exceed 30 seconds of request duration, increase `responseHeaderTimeout` to match the larger request budget.

Operationally, Traefik is not just the front door. It is also part of the safety system because `nscale` relies on consistent routing and, optionally, Traefik request metrics to make scale-down decisions.

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
- distributed scale-down lock

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
  its cache from the same source of truth.

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

The short idle timeout means services become eligible for scale-down quickly. The proxy timeout covers the wake budget (60s) plus a small margin for the fast response.

### Slow batch or processing services (10–60s response time)

For services that hold connections open for extended work:

```toml
[default.scaling]
idle_timeout_secs = 60
scale_down_interval_secs = 10

[default.proxy]
request_timeout_secs = 120
```

The longer idle timeout gives heartbeats plenty of room (every 20 seconds). The proxy timeout covers wake budget (60s) plus the full backend work window. The slower sweep interval reduces unnecessary scale-down checks.

### Mixed fleet (fast and slow services together)

Use the recommended baseline profile. It is calibrated for the worst-case service (slow) while remaining responsive enough for fast services.
