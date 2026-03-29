# nscale — Nomad Scale-to-Zero

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Transparent scale-to-zero and wake-on-request for [HashiCorp Nomad](https://www.nomadproject.io/) services.
**nscale** sits between Traefik and your Nomad jobs — when traffic arrives for a dormant service,
it wakes the job, proxies the request, and scales idle services back to zero when they go quiet.

## Architecture

```
                  ┌──────────┐
  request ──────► │  Traefik │
                  └────┬─────┘
                       │
          ┌────────────┼────────────┐
          │ healthy    │  dormant   │
          ▼            ▼            │
     ┌─────────┐  ┌────────┐       │
     │ Backend │  │ nscale │       │
     └─────────┘  └───┬────┘       │
                      │            │
           wake ──────┤            │
           proxy ─────┤            │
           scale ─────┘            │
                                   │
                  once healthy ────┘
                  Traefik routes
                  directly
```

**nscale** is a single Rust binary composed of seven internal crates:

| Crate | Purpose |
|-------|---------|
| `nscale-core` | Shared types, config (figment), traits |
| `nscale-nomad` | Nomad API client — scale up/down, allocation discovery |
| `nscale-consul` | Consul catalog — health checks, service discovery |
| `nscale-store` | Redis activity store and job registry |
| `nscale-proxy` | Reverse proxy with retry-on-502 and cache invalidation |
| `nscale-waker` | Wake coordinator — request coalescing, state machine |
| `nscale-scaler` | Scale-down controller with Traefik traffic probe |

## Features

- **Wake-on-request** — Dormant services are started automatically when traffic arrives
- **Request coalescing** — Concurrent requests for the same service share a single wake cycle
- **Reverse proxy** — First request is proxied through nscale; subsequent requests go directly via Traefik
- **Idle detection** — Services with no recent activity are scaled to zero
- **Traffic probe** — Scrapes Traefik Prometheus metrics to prevent scaling down services with active traffic
- **Retry with cache invalidation** — On upstream failure, invalidates stale endpoints and retries the full wake cycle
- **Active-deployment tolerance** — Gracefully handles Nomad 400 "scaling blocked due to active deployment"
- **Bounded concurrency** — Configurable limit on simultaneous Nomad scale operations

## Quick Start

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- [Nomad](https://developer.hashicorp.com/nomad/install) 1.10+
- [Consul](https://developer.hashicorp.com/consul/install) 1.18+

### Run with Docker Compose

The integration stack brings up Nomad, Consul, Redis, Traefik, and nscale:

```bash
cd integration
docker compose up -d
```

Register a sample job:

```bash
# Submit the echo service (starts dormant at count=0)
nomad job run jobs/echo-s2z.nomad

# Register it with nscale
curl -X POST http://localhost:9090/admin/registry \
  -H 'Content-Type: application/json' \
  -d '{"job_id": "echo-s2z", "host": "echo.localhost", "service_name": "echo-s2z"}'
```

Send a request — nscale wakes the service and proxies the response:

```bash
curl -H "Host: echo-s2z.localhost" http://localhost:8080/
```

### Build from source

```bash
cargo build --release
./target/release/nscale
```

### Docker

```bash
docker build -t nscale .
docker run -p 8080:8080 -p 9090:9090 nscale
```

## Configuration

nscale uses [figment](https://docs.rs/figment) for layered configuration:
**Environment variables > TOML file > Defaults**.

### TOML (`config/default.toml`)

```toml
[default]
listen_addr = "0.0.0.0:8080"
admin_addr  = "0.0.0.0:9090"

[default.nomad]
addr        = "http://localhost:4646"
concurrency = 50

[default.consul]
addr = "http://localhost:8500"

[default.redis]
url = "redis://localhost:6379"

[default.scaling]
idle_timeout_secs        = 300
wake_timeout_secs        = 60
scale_down_interval_secs = 30
min_scale_down_age_secs  = 120

[default.proxy]
request_timeout_secs = 30
request_buffer_size  = 1000
```

### Environment variables

All settings can be overridden with `NSCALE_` prefixed env vars:

| Variable | Default | Description |
|----------|---------|-------------|
| `NSCALE_LISTEN_ADDR` | `0.0.0.0:8080` | Proxy listen address |
| `NSCALE_ADMIN_ADDR` | `0.0.0.0:9090` | Admin/health listen address |
| `NSCALE_NOMAD__ADDR` | `http://localhost:4646` | Nomad API address |
| `NSCALE_NOMAD__TOKEN` | — | Nomad ACL token (optional) |
| `NSCALE_NOMAD__CONCURRENCY` | `50` | Max concurrent Nomad operations |
| `NSCALE_CONSUL__ADDR` | `http://localhost:8500` | Consul API address |
| `NSCALE_CONSUL__TOKEN` | — | Consul ACL token (optional) |
| `NSCALE_REDIS__URL` | `redis://localhost:6379` | Redis connection URL |
| `NSCALE_SCALING__IDLE_TIMEOUT_SECS` | `300` | Seconds before idle service is scaled down |
| `NSCALE_SCALING__WAKE_TIMEOUT_SECS` | `60` | Max seconds to wait for a service to become healthy |
| `NSCALE_SCALING__SCALE_DOWN_INTERVAL_SECS` | `30` | Scale-down sweep interval |
| `NSCALE_TRAEFIK__METRICS_URL` | — | Traefik Prometheus endpoint (enables traffic probe) |
| `NSCALE_TRAEFIK__PROVIDER` | — | Traefik provider name for metric labels |
| `RUST_LOG` | `info,nscale=debug` | Tracing filter |

## Admin API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/healthz` | Liveness check |
| `GET` | `/readyz` | Readiness check (verifies Redis) |
| `POST` | `/admin/registry` | Register a single job |
| `POST` | `/admin/registry/sync` | Bulk-sync all job registrations |

## Testing

### Unit tests

```bash
cargo test --workspace
```

### Integration / stress tests (k6)

```bash
cd integration

# Cold-start latency
./test.sh                        # basic test
K6_SCRIPT=k6/coldstart.js ./test.sh

# Load test
K6_SCRIPT=k6/load.js ./test.sh

# Storm (concurrent cold starts)
K6_SCRIPT=k6/storm.js ./test.sh

# Multi-service chaos
./stress-test.sh                 # 50 services + chaos killing
```

## How It Works

1. **Dormant state** — A Nomad job is registered with nscale at `count = 0`. Traefik has no healthy backend, so requests fall through to nscale via an error-fallback middleware.

2. **Wake cycle** — nscale receives the request, looks up the job in its registry, and calls `POST /v1/job/{id}/scale` to Nomad. It then polls Consul health checks until a healthy allocation appears.

3. **Proxy** — The first request is proxied through nscale to the newly healthy backend. The wake coordinator caches the endpoint so concurrent requests share the same wake cycle.

4. **Direct routing** — Once the service is healthy in Consul, Traefik routes subsequent requests directly — nscale is out of the data path.

5. **Scale down** — The scale-down controller periodically scans Redis for idle services. Before scaling down, it checks the Traefik traffic probe to ensure there's no active traffic. If the service is truly idle, it scales the Nomad job to `count = 0` and invalidates the coordinator cache.

## Project Structure

```
├── Cargo.toml              # Workspace + binary definition
├── src/main.rs             # Binary entrypoint
├── crates/
│   ├── nscale-core/        # Config, traits, shared types
│   ├── nscale-nomad/       # Nomad API client
│   ├── nscale-consul/      # Consul catalog client
│   ├── nscale-store/       # Redis activity store + job registry
│   ├── nscale-proxy/       # Reverse proxy + activity middleware
│   ├── nscale-waker/       # Wake coordinator (state machine)
│   └── nscale-scaler/      # Scale-down controller + traffic probe
├── config/
│   └── default.toml        # Default configuration
├── integration/
│   ├── docker-compose.yml  # Full local stack
│   ├── jobs/               # Sample Nomad job specs
│   ├── k6/                 # Stress & chaos test scripts
│   ├── scripts/            # Helper scripts
│   └── traefik/            # Traefik configuration
├── Dockerfile              # Multi-stage production build
├── CHANGELOG.md
├── CONTRIBUTING.md
└── LICENSE                 # Apache 2.0
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
