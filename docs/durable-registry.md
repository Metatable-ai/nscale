# Durable registry mode

This guide explains how `nscale` stores job registrations when durable registry mode is enabled.

In this mode:

1. etcd is the source of truth for `JobRegistration` data
2. Redis remains the fast cache used by the proxy, scaler, and event processor
3. cache misses are repaired by reading from etcd and writing the result back to Redis
4. repeated writes are idempotent, so multiple replicas can safely register the same job

This is the recommended mode when you expect to run more than one `nscale` replica or when you want
registry data to survive Redis cache loss.

## Data model

Each registration is stored under two durable keys in etcd:

- job lookup: `/nscale/registrations/jobs/<job_id>`
- service lookup: `/nscale/registrations/services/<service_name>`

The value in each key is the JSON-serialized `JobRegistration`:

```json
{
  "job_id": "echo-submit-job",
  "service_name": "echo-s2z",
  "nomad_group": "main"
}
```

Redis keeps the same two lookup shapes in the hashes used by the current registry cache:

- `nscale:jobs`
- `nscale:jobs:services`

## Read path

`JobRegistry::get()` uses cache-aside behavior:

1. look in Redis by job ID
2. if that misses, look in Redis by service name
3. if Redis misses and durable mode is enabled, query etcd
4. repopulate Redis from the durable result
5. return the registration

This keeps the request path fast while still allowing recovery from Redis loss.

## Write path

When durable mode is enabled, registration writes are durable-first:

1. write to etcd
2. write to Redis cache

If etcd fails, the write fails. That prevents Redis from being populated with data that is not durable.

## Recovery behavior

On startup, nscale can hydrate Redis from etcd before handling traffic.

In multi-replica deployments, each replica can repair its local Redis cache independently. That
means a cache loss on one replica does not require manual per-job re-registration.

This is the behavior covered by:

- `integration/test-durable.sh`
- `integration/test-durable-multi-replica.sh`

## Configuration

Enable durable registry mode with:

```toml
[default.registry]
durable_enabled = true
etcd_endpoints = "http://etcd:2379"
etcd_key_prefix = "/nscale/registrations"
etcd_watch_backoff_secs = 5
```

Equivalent environment variables:

- `NSCALE_REGISTRY__DURABLE_ENABLED=true`
- `NSCALE_REGISTRY__ETCD_ENDPOINTS=http://etcd:2379`
- `NSCALE_REGISTRY__ETCD_KEY_PREFIX=/nscale/registrations`
- `NSCALE_REGISTRY__ETCD_WATCH_BACKOFF_SECS=5`

## When to use it

Use durable registry mode when:

- you run more than one `nscale` replica
- you want registry data to survive Redis cache loss
- you want read-through cache repair without manual `/admin/registry` calls

Keep it disabled when:

- you only want the default Redis-only behavior
- you are experimenting locally and do not want an etcd dependency

## Test commands

```bash
cd integration
./test-durable.sh
./test-durable-multi-replica.sh
```

The multi-replica test proves that replica B can read through to etcd after replica A writes the
registration and Redis is cleared.