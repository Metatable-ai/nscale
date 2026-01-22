<!--
// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0
-->

# Idle Scaler

Runs a periodic check against Nomad jobs marked with scale-to-zero metadata and scales idle groups to 0.

## Run

```bash
NOMAD_ADDR=http://localhost:4646 \
CONSUL_ADDR=http://localhost:8500 \
IDLE_CHECK_INTERVAL=30s \
DEFAULT_IDLE_TIMEOUT=5m \
go run .
```

### Using Redis Backend

For high-volume environments, use Redis instead of Consul KV to reduce Raft pressure:

```bash
NOMAD_ADDR=http://localhost:4646 \
CONSUL_ADDR=http://localhost:8500 \
REDIS_ADDR=localhost:6379 \
STORE_TYPE=redis \
go run .
```

## Configuration

| Flag/Env | Default | Description |
|----------|---------|-------------|
| `-nomad-addr` / `NOMAD_ADDR` | `http://localhost:4646` | Nomad API address |
| `-consul-addr` / `CONSUL_ADDR` | `http://localhost:8500` | Consul address (for service discovery) |
| `-redis-addr` / `REDIS_ADDR` | `` | Redis address (optional) |
| `-redis-password` / `REDIS_PASSWORD` | `` | Redis password |
| `-redis-db` / `REDIS_DB` | `0` | Redis database number |
| `-store-type` / `STORE_TYPE` | `consul` | Store type: `consul` or `redis` |
| `-interval` / `IDLE_CHECK_INTERVAL` | `30s` | Idle check interval |
| `-default-idle-timeout` / `DEFAULT_IDLE_TIMEOUT` | `5m` | Default idle timeout |

## Metadata

- `scale-to-zero.enabled=true`
- `scale-to-zero.idle-timeout=60` (seconds)

## How It Works

1. Lists all Nomad jobs with `scale-to-zero.enabled=true`
2. Stores each job spec (only if changed) for later revival by scalewaker
3. Checks last activity timestamp from activity store
4. If `now - lastActivity > idleTimeout` → scales job to 0

## Storage Backends

### Consul KV (default)
- Good for small deployments (<50 jobs)
- Uses in-memory hash to avoid redundant writes
- Keys: `scale-to-zero/jobs/<job-id>`

### Redis (recommended for large deployments)
- Better write performance for high-volume environments
- Uses hash comparison to write only on change
- Reduces Raft pressure on Consul cluster

## Dead Job Revival

Dead jobs are **not** revived by idle-scaler. Instead, when a request arrives at Traefik, the **scalewaker** middleware:
1. Detects the job is dead/not-found
2. Re-registers the job from the stored spec
3. Scales the job to 1
4. Waits for the service to become healthy
5. Forwards the request
