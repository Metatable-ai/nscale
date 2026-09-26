# Job submission through nscale

This guide explains how to submit Nomad jobs through `nscale` instead of talking to Nomad directly.

The `/admin/jobs` endpoint is the preferred path when you want `nscale` to own the full service-management flow:

1. parse Nomad HCL with optional variables
2. inject the Traefik router service override required for warm-path routing through `nscale`
3. submit the mutated job to Nomad
4. replace the job’s complete managed-service set in Redis, and in etcd when durable mode is enabled
5. seed activity so the scaler can safely detect future idleness

## Why use `/admin/jobs`

Submitting through `nscale` removes a brittle manual step.

Without it, operators have to do two things correctly every time:

- submit a Nomad job with the right Traefik `...service=s2z-nscale@file` tags
- call `/admin/registry` or `/admin/registry/sync` so `nscale` can wake and scale the job later

With `/admin/jobs`, `nscale` does both automatically.

When durable registry mode is enabled, that automatic registration becomes durable-first:

- write the registration to etcd
- refresh the Redis cache from the durable result
- repopulate Redis on cache miss if a replica needs to read through later

## Request format

`POST /admin/jobs`

```json
{
  "hcl": "job \"echo-submit-job\" { ... }",
  "variables": "service_name = \"echo-s2z\"\nhost_name = \"echo-s2z.localhost\""
}
```

### Fields

| Field | Required | Description |
|---|---|---|
| `hcl` | yes | The Nomad job file contents in HCL format |
| `variables` | no | Optional Nomad variable assignments passed to the HCL parser |
| `autoscaling` | no | Policy applied to every managed service; `max_count` is required when supplied |

The `variables` string is forwarded to Nomad's parser exactly as provided.

An optional policy can be added alongside `hcl` and `variables`:

```json
{
  "max_count": 5,
  "min_count": 2,
  "scale_to_zero": false,
  "target_requests_per_second_per_instance": 25.0
}
```

Put this object under `autoscaling`. See the [policy reference](../README.md#per-job-autoscaling)
for all fields. Validation runs before Nomad submission. Without a policy, the submitted job
uses scale-to-zero behavior; omitting it on replacement removes the previous autoscaling policy.

For a complete before/after payload and push command, see the
[migration comparison](./migration-autoscaling.md#job-push-example-previous-release-versus-autoscaling-release).

## Example

The repository includes a working fixture at `integration/jobs/echo-submit.nomad`.
You can submit it like this:

```bash
cd integration

curl -X POST http://localhost:9090/admin/jobs \
  -H 'Content-Type: application/json' \
  --data "$(jq -n \
    --rawfile hcl jobs/echo-submit.nomad \
    --arg variables $'service_name = \"echo-s2z\"\nhost_name = \"echo-s2z.localhost\"' \
    '{hcl: $hcl, variables: $variables}')"
```

`jq` is used only to escape the multi-line HCL and variables safely into JSON.

## What nscale injects

For each Traefik-enabled service, `nscale` discovers the router names already present in tags like:

- `traefik.http.routers.api.rule=...`
- `traefik.http.routers.api.entryPoints=...`

Then it injects or overrides:

- `traefik.http.routers.api.service=s2z-nscale@file`

The exact target is configurable through `routing.file_provider_service` or
`NSCALE_ROUTING__FILE_PROVIDER_SERVICE`.

`nscale` does **not** strip or rewrite HTTPS-related router tags. Jobs like the following are
supported as-is:

- `traefik.http.routers.api.entryPoints=http,https`
- `traefik.http.routers.api.tls=true`

That means `nscale` keeps your edge-TLS intent intact and only rewires the router target back to
the file-provider service.

> Important: Traefik still needs an HTTPS fallback router pointing at `s2z-nscale` for cold-path
> TLS requests. The repository integration stack and hybrid Kubernetes setup now include that by
> default.

## Service requirements

A service is managed by `/admin/jobs` only when all of the following are true:

- it has `traefik.enable=true`
- it has at least one explicit router tag under `traefik.http.routers.<name>.*`
- it lives in either a task-level or group-level `service` block that Nomad exposes in parsed JSON

### What gets ignored

- services without `traefik.enable=true`
- internal or sidecar services that are not meant to be routed through Traefik

### What gets rejected

Traefik-enabled services with no explicit router tags are rejected.

That is intentional: `nscale` needs the router name in order to inject the correct
`traefik.http.routers.<name>.service=...` override.

## Auto-registration behavior

After submitting the job, `nscale` registers every managed service as a `JobRegistration`:

```json
{
  "job_id": "echo-submit-job",
  "service_name": "echo-s2z",
  "nomad_group": "main"
}
```

That registration is used by:

- the proxy lookup path
- wake-on-request
- the scale-down controller
- idle activity seeding

This is especially important when `service_name` differs from `job_id`.
Proxy lookup uses the exact service identity; administrative lookup also accepts the job alias.

If durable registry mode is enabled, the same `JobRegistration` is also persisted in etcd so
another replica can recover the cache later without manual per-job re-registration.

## Replacing an existing job

A successful submission replaces all nscale-managed registrations for that job. Services removed,
renamed, or no longer Traefik-enabled are removed from the registry. Retained services receive the
new policy and group mapping. Unrelated jobs are preserved. A job with no managed services is
rejected; use the purge endpoint when removing the entire job.

Submission and replacement hold the shared Nomad-job mutation lease. Redis replaces both indexes
in one operation; durable mode first replaces the job’s etcd entries in one transaction. Local
endpoint pools for affected units are invalidated, and current units receive an activity timestamp.
A failed Nomad submission leaves the previous registration set intact.

This replacement behavior belongs to `/admin/jobs`. Manual `/admin/registry` and
`/admin/registry/sync` requests upsert the supplied registrations; they do not remove omitted services.

## Response shape

Successful responses return the submitted Nomad evaluation data plus the services that were managed:

```json
{
  "job_id": "echo-submit-job",
  "eval_id": "b1f37c02-ebc3-de7d-27b4-24cecd665c56",
  "job_modify_index": 1234,
  "warnings": null,
  "managed_services": [
    {
      "job_id": "echo-submit-job",
      "service_name": "echo-s2z",
      "nomad_group": "main"
    }
  ],
  "registration_failures": []
}
```

| Status | Meaning | Operator action |
|---|---|---|
| `201 Created` | Nomad accepted the job and the registration set was replaced | Check deployment and service health; acceptance does not mean allocations are healthy yet |
| `409 Conflict` | Another mutation owns the job lease; this request has not submitted to Nomad | Retry with backoff |
| `207 Multi-Status` | Nomad accepted the job, but registration replacement failed | Inspect `registration_failures`, restore the failing store, and resubmit the same desired job and policy |

Nomad, etcd, and Redis do not share a transaction. In particular, etcd may contain the replacement
while Redis still holds the previous set if the cache write fails. A successful retry reconciles
both stores. Do not interpret `207` as a completed deployment or assume a process restart prunes
stale registrations.

## Direct Nomad submit vs `/admin/jobs`

Use `/admin/jobs` when:

- you want `nscale` to inject the required Traefik service override automatically
- you want automatic registration and activity seeding
- you want the integration-tested path used by this repository's main end-to-end tests

Use `/admin/registry` or `/admin/registry/sync` when:

- a job is submitted by another system outside `nscale`
- the job already contains the correct routing tags
- you only need to teach `nscale` about an existing service

Use `DELETE /admin/jobs/:job_id` when:

- the Nomad job should be stopped and purged
- you want `nscale` to clear cached wake state, activity, and registrations for that job
- you want a safety guard that rejects the purge while requests are in flight unless you pass `?force=true`

`nscale` also has an automatic stale-registration cleanup policy under
`scaling.auto_deregister`. When Nomad reports a registered job missing
repeatedly, `nscale` increments a shared Redis counter and removes the
registration once the configured `not_found_threshold` is reached.

## Nomad HCL limitations

Nomad variables work inside attribute values, but not in block labels.

For example, this is fine:

```hcl
service {
  name = var.service_name
}
```

But this is not:

```hcl
job "${var.job_id}" {
  # invalid for Nomad's HCL parser
}
```

If you need variableized names, keep block labels literal and apply variables inside the block body.

## Validation and regression coverage

Available Docker and Kubernetes integration scripts include:

- `integration/test.sh`
- `integration/test-acl.sh`
- `nscale-kubernetes/test-hybrid.sh`
- `integration/test-durable.sh`
- `integration/test-durable-multi-replica.sh`

The main Docker integration test verifies that `/admin/jobs`:

- accepts HCL plus variables
- injects the Traefik service override tag
- auto-registers the service
- works when `service_name != job_id`
- still supports wake-on-request and scale-to-zero over both HTTP and HTTPS

The durable integration tests verify that:

- registrations survive Redis cache loss when etcd is available
- a second nscale replica can read through to etcd and repopulate Redis
- service lookup still works when `service_name != job_id`

The current [release evidence](./autoscaling-release-readiness.md) distinguishes scripts run on
the latest changes from earlier passes. The latest durable test also renames a service and checks
removal from both stores. Opt-in Rust tests cover removed sibling policies, rejected/busy
submissions, preservation of unrelated jobs, and cache restoration.
