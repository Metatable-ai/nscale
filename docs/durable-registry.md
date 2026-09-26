# Durable registry mode

This guide explains how `nscale` stores job registrations when durable registry mode is enabled.

In this mode:

1. etcd is the source of truth for `JobRegistration` data
2. Redis remains the fast cache used by the proxy, scaler, and event processor
3. cache misses are repaired by reading from etcd and writing the result back to Redis
4. replicas share the same Redis store for registry caching, request leases, and mutation coordination

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

Proxy requests resolve the exact service name in Redis, then read through to etcd on a cache
miss. A job alias must not resolve to a different service. Administrative `JobRegistry::get()`
lookups retain job-ID-first behavior, with service-name fallback.

The job key is a compatibility alias for one registration. The service keys hold the complete
set for jobs with multiple services; do not use the job alias to enumerate a job’s services.

Redis connection errors are not cache misses. Durable mode restores registration data after
cache loss; it does not let the proxy admit requests during a Redis outage.

## Write path

When durable mode is enabled, registration writes are durable-first:

1. write to etcd
2. write to Redis cache

If etcd fails, the write fails. That prevents Redis from being populated with data that is not durable.

For `/admin/jobs`, the complete registration set for one job is replaced under the shared job
mutation lease: one etcd transaction removes obsolete service keys and writes the current set,
then one Redis operation replaces both cache indexes. Other jobs are preserved. Manual registry
endpoints continue to upsert individual registrations.

If Nomad accepted a submission but either registry write fails, `/admin/jobs` returns `207` with
failure details. A Redis failure after the etcd transaction can leave the old cache alongside
new durable data. Restore store connectivity and resubmit the desired job and policy; see
[submission recovery](./job-submission.md#response-shape). There is no cross-store transaction.

## Recovery behavior

On startup, nscale attempts to hydrate registrations from etcd before serving traffic; hydration
errors are logged. During operation,
either proxy replica can read through to etcd and repopulate the **shared** Redis cache.

Hydration and cache misses restore entries; they are not continuous reconciliation. There is no
active etcd watch, and startup hydration does not prune every stale cached entry. Avoid changing
etcd keys directly, and retry partially successful submissions rather than relying on restart.

The latest `integration/test-durable.sh` run verifies replacement removes a renamed service from
both stores, then tests warm and cold requests after cache loss. The separate
`integration/test-durable-multi-replica.sh` exercises peer read-through; consult the
[release evidence](./autoscaling-release-readiness.md) before treating an available test as a
fresh pass on the final candidate.

## Upgrading

Use the [migration guide](./migration-autoscaling.md) for coordinated proxy replacement and rollback.
Keep Redis non-evicting: durable registry recovery does not restore lost live request tokens or
mutation locks. Enabling durable mode is not an automatic Redis-to-etcd migration.

## Configuration

Enable durable registry mode with:

```toml
[default.registry]
durable_enabled = true
etcd_endpoints = "http://etcd:2379"
etcd_key_prefix = "/nscale/registrations"
# Reserved for future watch/reconcile wiring; currently unused.
etcd_watch_backoff_secs = 5
```

Equivalent environment variables:

- `NSCALE_REGISTRY__DURABLE_ENABLED=true`
- `NSCALE_REGISTRY__ETCD_ENDPOINTS=http://etcd:2379`
- `NSCALE_REGISTRY__ETCD_KEY_PREFIX=/nscale/registrations`
- `NSCALE_REGISTRY__ETCD_WATCH_BACKOFF_SECS=5` (reserved for future watch/reconcile wiring; currently unused)

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
