# Migrating from 2.2.x to 3.0.0

This guide covers the **3.0.0 autoscaling release candidate from the Rust 2.2.x line**.
The source comparison uses local tag `v2.2.2` (`e8d5499`, WebSocket tunneling).
For an older or customized installation, also compare its configuration and registration format.
This is not a migration guide for the pre-2.0 Go implementation.

Cargo workspace packages, Helm chart version, and chart `appVersion` are aligned at **3.0.0**.
An empty Helm `image.tag` selects `3.0.0`; pin the tested artifact explicitly (or use an immutable
digest in your deployment tooling). Updating metadata does not publish the image: verify the
candidate exists in your registry before upgrading. Do not substitute `latest`.

**Plan a maintenance cutover. Do not mix old and new proxy/controller versions against the same
jobs and Redis.** Old replicas do not publish the new shared request tokens or participate in all
mutation leases. A normal rolling update or blue/green overlap cannot provide these guarantees.
The application has no global pause/drain API, and its current server wiring does not provide a
SIGTERM-driven request drain. Drain externally before stopping processes.

The [release-readiness gates](./autoscaling-release-readiness.md) still apply. The migration sequence
below has been checked against source and chart rendering; a complete old-to-new rollout and
rollback has not yet been exercised in staging.

## Compatibility and behavior changes

| Area | Upgrade behavior | Required action |
|---|---|---|
| Existing single-group registrations | Old three-field JSON remains readable; absent policy means scale-to-zero behavior | Keep existing stores and IDs; no blanket data rewrite or Redis flush |
| Multi-group registrations | Legacy records without `scale_unit` still use the job ID; startup does not infer new group mappings | Reconcile every managed service to the correct `job_id/group` unit before enabling traffic |
| Autoscaling | Opt-in per registration; no global enable/disable switch | Initially leave policies absent, then enable one canary group |
| Request coordination | Redis now holds correctness-sensitive request tokens and renewable mutation leases | Use the same non-evicting Redis store across replicas, with memory headroom and required commands |
| Routing/discovery | Exact service-name lookup and per-service round-robin pools | Confirm service names, Host routing, router tags, and all healthy allocation ports |
| `/admin/jobs` | A successful submit replaces the entire managed service set for the job | Submit complete desired HCL and policy; omitted services/policies are removed |
| Admin access | Optional bearer token protects `/admin/*`; health and metrics remain public | Update automation before enabling `NSCALE_ADMIN__TOKEN` |
| Metrics | Aggregate latency uses histogram buckets; local latency/error observations cannot authorize reductions | Scrape all proxies; update dashboards and provide aggregate signals for latency/error downsizing |
| Timeouts/retries | Wake queue time is inside the wake deadline; only empty GET/HEAD requests are replayed | Check client/ingress deadlines; retain application-level handling for non-replayable requests |

## 1. Inventory and prepare recovery

Record the exact deployed binary/image, chart revision, replica count, config, environment overrides,
Secret references, Redis database, and etcd prefix. Preserve the previous artifacts and manifests.
Pause GitOps reconciliation, HPA actions, and automation that could restart old replicas or submit
jobs during the maintenance window. Include replicas outside the primary deployment.

Inventory **all** managed services and Nomad groups, their current counts, complete desired job
specifications, routing tags, and any external scaling controllers. One group must have one scaling
owner. Record long-lived HTTP requests and WebSockets that must finish or reconnect during cutover.

Take recoverable backups of the Redis state and, if enabled, etcd using your storage backup procedure.
Also export the registry payloads for inspection/replay. For an operator workstation already configured
for Redis authentication/TLS, the following exports the two indexes separately:

```bash
# Set REDIS_HOST, REDIS_PORT, REDIS_DB and configure authentication/TLS for your environment.
# Add the required redis-cli TLS options to both calls when applicable.
set -euo pipefail
: "${REDIS_HOST:?Set the reviewed Redis host}"
: "${REDIS_PORT:?Set the reviewed Redis port}"
: "${REDIS_DB:?Set the reviewed Redis database}"
umask 077
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -n "$REDIS_DB" --raw \
  HVALS nscale:jobs:services | jq -s '.' > registry-services.before.json
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -n "$REDIS_DB" --raw \
  HVALS nscale:jobs | jq -s '.' > registry-job-aliases.before.json
```

These JSON exports are registration inventories, not complete Redis backups. Check command success,
parse the files, and compare them with Nomad. A job alias contains only one service; it cannot
reconstruct a multi-service job. If service keys are missing, recover the full set from authoritative
job definitions before proceeding. Keep backups private; do not put credentials or exported manifests
in Git. Take the final consistent snapshot after all old nscale processes have stopped in step 3.

## 2. Prepare the target configuration

Keep the existing Redis endpoint/database and etcd prefix for the initial upgrade. Do not combine
this cutover with a store migration or first-time durable-registry enablement. Enabling etcd does
not automatically export existing Redis registrations into it.

### Redis is no longer only a disposable cache

The 3.0.0 chart defaults to `maxmemory-policy noeviction`. **Replace any inherited
`allkeys-lru` configuration in your existing Helm values or external Redis before using shared
request coordination.** Otherwise memory pressure
can silently remove an active request token or mutation lock. Keep enough headroom for registry,
activity, request tokens, and cooldowns; alert on memory pressure and rejected writes. With no
available memory, rejected admission is preferable to silently losing coordination state.

For bundled Redis, edit the complete existing `redis.config` value, preserving authentication and
other deployment-specific settings. The chart accepts a full string, not a partial Redis setting.
Changing it restarts the bundled Redis deployment. Its defaults disable persistence and use
`dir /tmp`; merely enabling the PVC at `/data` does not make that default configuration durable.
A Redis-only registry therefore needs a verified backup/replay plan before that restart. With etcd,
verify durable entries are complete before relying on cache hydration. Do not change eviction or
restart Redis while old requests are still draining.

Redis access must allow the hash, sorted-set, expiring-key, and Lua operations used by nscale,
including `EVAL` and the commands invoked by its scripts. Verify the actual ACL in staging.
The multi-key registry replacement assumes the configured single Redis store; this guide does
not establish Redis Cluster compatibility.

### New settings and client changes

Existing nested environment names continue to use **double underscores**. New optional settings:

| Environment variable | Default | Purpose |
|---|---|---|
| `NSCALE_PROXY__ENDPOINT_REFRESH_SECS` | `2` | Refresh each service’s healthy endpoint pool |
| `NSCALE_PROMETHEUS__URL` | unset | Aggregate metrics query endpoint |
| `NSCALE_PROMETHEUS__TIMEOUT_SECS` | `5` | Prometheus query timeout |
| `NSCALE_ADMIN__TOKEN` | unset | Bearer token for privileged admin operations |

The chart exposes these settings directly. For example, in your reviewed upgrade values:

```yaml
image:
  tag: "3.0.0"
config:
  proxy:
    endpointRefreshSecs: 2
  admin:
    existingSecret: nscale-admin
    secretKey: token
externalServices:
  prometheus:
    url: http://prometheus.monitoring.svc.cluster.local:9090
    timeoutSecs: 5
```

Use your actual metrics endpoint and an already provisioned Secret. If upgrading from an earlier
example using `extraEnv`, remove duplicate entries for these settings when adopting chart values;
environment variables override TOML. Keep other required environment entries. The chart also exposes
`config.scaling.autoDeregister.enabled` and `config.scaling.autoDeregister.notFoundThreshold`.
Probes and Prometheus do not need the admin bearer token; registry/job clients do. Ensure Nomad/Consul ACLs still permit submission,
count reads/scaling, discovery, and events. Retain routing through nscale on both warm and cold paths.

Wake and backend timeouts are separate. Request heartbeats are now clamped to 100 ms–5 s, and shared
request tokens expire after 30 s without renewal. See the [performance guide](./performance-configuration.md)
for ingress budgets and shutdown constraints. Increasing an idle timeout is not a global scaling pause;
`min_scale_down_age_secs` is currently unused.

## 3. Drain and stop every old replica

1. Route **new** managed-service traffic to a maintenance response at the ingress/load balancer,
   while allowing existing connections to finish. Freeze admin writes and external job updates.
2. Wait for in-flight HTTP bodies and WebSocket tunnels to close, or use the application’s planned
   reconnect procedure. Old versions lack the new shared request census; verify draining with
   ingress/application telemetry. A quiet registry or `/readyz` response is not proof of zero traffic.
3. Stop all old nscale processes/controllers and verify none can restart automatically. Do not rely
   on Kubernetes termination grace alone to drain this binary. Leave Nomad workloads and storage up.
4. Take the final consistent backups. Apply any Redis configuration change now, check its effective
   eviction policy, and restore/replay registration data if a Redis restart lost it.

Stopping all proxies creates a deliberate maintenance interval. Idle controllers may have changed
workload counts before they stopped; compare actual Nomad counts with the inventory during validation.
There is no need to purge Nomad jobs or flush Redis as part of this upgrade.

### Kubernetes/Helm cutover example

These are operator-run commands after external drain, using the correct context/namespace. Set
`RELEASE`, `NSCALE_NAMESPACE`, `NSCALE_DEPLOYMENT`, `NSCALE_TARGET_TAG`, and `NSCALE_REPLICAS` to the
reviewed values. The selector below matches the app component in this repository’s chart; confirm
it matches every proxy deployment in your installation.

```bash
kubectl -n "$NSCALE_NAMESPACE" scale deployment "$NSCALE_DEPLOYMENT" --replicas=0
kubectl -n "$NSCALE_NAMESPACE" wait --for=delete pod \
  -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=app" --timeout=180s

# reviewed-values.yaml preserves your existing dependencies, Secrets and overrides,
# including the non-evicting Redis configuration. Keep proxies stopped for this phase.
helm upgrade "$RELEASE" ./charts/nscale -n "$NSCALE_NAMESPACE" \
  -f reviewed-values.yaml --set-string image.tag="$NSCALE_TARGET_TAG" \
  --set replicaCount=0 --wait --timeout=5m

# Confirm storage is healthy, backups/restoration are complete, and old pods are gone.
helm upgrade "$RELEASE" ./charts/nscale -n "$NSCALE_NAMESPACE" \
  -f reviewed-values.yaml --set-string image.tag="$NSCALE_TARGET_TAG" \
  --set replicaCount="$NSCALE_REPLICAS" --wait --timeout=5m
kubectl -n "$NSCALE_NAMESPACE" rollout status deployment "$NSCALE_DEPLOYMENT" --timeout=5m
```

Before running the upgrade, render the same chart and values with `helm template` and inspect
image tags, app replica count, Secret references, selectors, Redis config, and storage mounts.
Keep ingress in maintenance through the following steps. A failed Helm wait is a reason to inspect
state, not to let automation launch the old image alongside new pods. The chart uses `Recreate` for the app deployment, but has no request-drain hooks. `Recreate` avoids
old/new pod overlap within this deployment; it does not drain traffic or coordinate other deployments.
Retain the explicit stop-all cutover for this major upgrade.
For Compose or systemd, follow the same sequence: externally drain, stop every old nscale instance,
replace its pinned image/binary and config, then start only the target version. Avoid `down -v` or
uninstalling the backing stores.

## 4. Reconcile registrations before reopening traffic

The new process starts its controllers immediately. There is no startup “migration-only” mode.
Legacy single-group records remain readable, and registrations without policies do not start
nonzero autoscaling. Reconcile promptly while ingress remains closed; idle scale-to-zero still runs.

For single-group jobs, keep `job_id`, `service_name`, and `nomad_group`; `scale_unit` may stay absent.
For jobs with multiple managed groups, every service must have the matching `job_id/group` unit.
Startup hydration does not infer these mappings or remove obsolete entries.

Prefer resubmitting the **complete desired job** through `/admin/jobs`, which derives group units
and router metadata and removes obsolete services. Preserve the intended Nomad counts when composing
that HCL: resubmission is a real job update and may create a deployment or change counts. Wait for
Nomad health before proceeding. No autoscaling policy is needed for the initial compatibility pass.

If another system owns job submission, use `/admin/registry/sync` with a reviewed complete inventory
instead. This endpoint changes registrations without submitting Nomad jobs. For example:

```json
[
  {
    "job_id": "shop",
    "service_name": "shop-web",
    "nomad_group": "web",
    "scale_unit": "shop/web",
    "traefik_routers": ["shop-web"]
  },
  {
    "job_id": "shop",
    "service_name": "shop-api",
    "nomad_group": "api",
    "scale_unit": "shop/api",
    "traefik_routers": ["shop-api"]
  }
]
```

Use actual service/group/router identities from Nomad and Traefik. Manual sync is an upsert, not a
replacement: it cannot remove retired services. Do not use `DELETE /admin/jobs/{job_id}` to clean
registry metadata; it purges the real Nomad job. If obsolete registrations need removal, resolve
ownership of a complete `/admin/jobs` replacement before proceeding.

For sync, inspect the JSON response: HTTP `200` is insufficient; require `failed == 0` and
`synced == total ==` the expected record count. For `/admin/jobs`, require `201`, retry `409` with
backoff, and treat `207` as incomplete: restore store health and resubmit the same desired HCL/policy.
Do not rely on startup hydration to repair stale cache entries after a partial replacement.

For a registry-only replay, save the reviewed array as `reviewed-registrations.json` and run:

```bash
# NSCALE_ADMIN_URL points to the target admin listener.
# NSCALE_CURL_CONFIG is a private curl config supplying your TLS/auth settings.
# Keep any bearer credential in that private file, not in the command line or Git.
set -euo pipefail
: "${NSCALE_ADMIN_URL:?Set the target admin URL}"
: "${NSCALE_CURL_CONFIG:?Set the private curl config path}"
curl --fail-with-body --silent --show-error --config "$NSCALE_CURL_CONFIG" \
  -H 'Content-Type: application/json' \
  --data-binary @reviewed-registrations.json \
  "$NSCALE_ADMIN_URL/admin/registry/sync" > registration-sync-result.json
jq -e --argjson expected "$(jq 'length' reviewed-registrations.json)" \
  '.failed == 0 and .synced == $expected and .total == $expected' \
  registration-sync-result.json
```

The [submission guide](./job-submission.md) has the alternative HCL submission payload. Do not use
`curl --fail` alone to validate `/admin/jobs`: `207` is a successful HTTP status class but an
incomplete registration result.

Read back the service registrations in Redis and optional etcd. Check every service, group, router,
and policy against the inventory. `GET /admin/autoscaling` lists only registrations with a policy,
so an empty result is expected before enabling autoscaling and is not a full registry inventory.

### Job push example: previous release versus autoscaling release

The endpoint is still `POST /admin/jobs`. The change is an optional `autoscaling` object beside
`hcl` and `variables`, plus complete registration replacement on successful submission.

This example uses the repository’s [echo job](../integration/jobs/echo-submit.nomad): job ID
`echo-submit-job`, group `main`, service `echo-s2z`, initial HCL `count = 1`. Its `raw_exec` task is
for the local integration environment. For your deployment, substitute the complete production
HCL and its variables, preserving the intended job ID, groups, and counts.

Run the payload-building commands from the repository root. They only write JSON files.
The two HTTP examples show alternative submissions: the first documents the previous workflow;
run the second only against the new version, after the canary prerequisites in step 5 are met.
Do not submit both to production just to compare them.

**Before: 2.2.x submission without an autoscaling policy**

```bash
jq -n \
  --rawfile hcl integration/jobs/echo-submit.nomad \
  --arg variables $'service_name = "echo-s2z"\nhost_name = "echo-s2z.localhost"' \
  '{hcl: $hcl, variables: $variables}' > job-before.json
```

The previous push sends that payload without a policy:

```bash
# Historical request shape; NSCALE_CURL_CONFIG supplies private TLS/auth settings.
curl --silent --show-error --config "$NSCALE_CURL_CONFIG" \
  -H 'Content-Type: application/json' \
  --data-binary @job-before.json \
  "$NSCALE_ADMIN_URL/admin/jobs"
```

That same policy-free payload remains accepted by the new release for the initial compatibility
pass. It registers scale-to-zero behavior without opting into load-driven running capacity.

**After: submit the same job with a bounded autoscaling policy**

```bash
jq '. + {
  autoscaling: {
    enabled: true,
    min_count: 1,
    max_count: 5,
    scale_to_zero: true,
    scale_up_step: 1,
    scale_down_step: 1,
    cooldown_secs: 120,
    decision_window_secs: 60,
    target_requests_per_second_per_instance: 25.0
  }
}' job-before.json > job-after.json
```

The HCL and variables are unchanged. The policy permits 1–5 running instances in group `main`,
with idle scale-to-zero still allowed. The request-rate target requires usable Traefik metrics,
either through the configured direct provider or Prometheus. The policy is nscale JSON; do not
paste it into a Nomad HCL `scaling` block or `config/default.toml`.

Push the new payload and explicitly check for complete registration success:

```bash
set -euo pipefail
: "${NSCALE_ADMIN_URL:?Set the target admin URL}"
: "${NSCALE_CURL_CONFIG:?Set the private curl config path}"
umask 077
submit_status=$(curl --silent --show-error --config "$NSCALE_CURL_CONFIG" \
  -H 'Content-Type: application/json' \
  --data-binary @job-after.json \
  --output job-submit-result.json --write-out '%{http_code}' \
  "$NSCALE_ADMIN_URL/admin/jobs")
if [ "$submit_status" != "201" ]; then
  printf 'Submission incomplete: HTTP %s; inspect job-submit-result.json\n' "$submit_status" >&2
  exit 1
fi
jq -e '
  .job_id == "echo-submit-job" and
  (.registration_failures | length) == 0 and
  (.managed_services | length) == 1 and
  .managed_services[0].service_name == "echo-s2z" and
  .managed_services[0].nomad_group == "main" and
  .managed_services[0].autoscaling.max_count == 5
' job-submit-result.json

curl --fail-with-body --silent --show-error --config "$NSCALE_CURL_CONFIG" \
  "$NSCALE_ADMIN_URL/admin/autoscaling" |
  jq '.jobs[] | select(.job_id == "echo-submit-job")'
```

For another job, update the response assertions as well as the HCL and variables. `201` confirms
submission and registration replacement; wait for Nomad deployment health and verify the policy
under traffic. On `409`, retry after the other mutation completes. On `207`, inspect
`registration_failures`, repair store availability, and resubmit the same desired payload.

| Behavior | Previous policy-free submission | New example |
|---|---|---|
| Endpoint and HCL | `/admin/jobs`, complete job HCL | Same endpoint and HCL |
| Initial submitted count | HCL `count = 1` | HCL `count = 1`; policy does not replace the initial HCL count |
| Load-driven running capacity | No nscale autoscaling policy | Between 1 and 5, subject to observations, step limits, and cooldowns |
| Idle behavior | Scale-to-zero | Still scale-to-zero because `scale_to_zero = true` |
| Cold request | Wake-on-request | Wake to `min_count = 1` |
| Removed service on resubmission | Old upsert flow could leave stale registrations | Removed from Redis and optional etcd after successful replacement |
| Subsequent policy-free submit | No policy | Removes the previous policy; include it on every submit if it should remain active |

To keep the canary running, set `scale_to_zero: false` in `job-after.json` before pushing. If you
choose `min_count: 2`, also review the HCL’s submitted count; a policy minimum is not a rewrite of
Nomad’s initial `Count`. With multiple groups, the submitted policy applies to every managed
service, and `max_count` is a per-group cap, not a total cap across the entire job.

## 5. Verify, then enable a canary policy

Keep public traffic closed while sending controlled probes through the real ingress path:

- `/healthz` and `/readyz` succeed on every target proxy. Readiness checks registry access, not
  end-to-end Nomad, Consul, metrics, or backend health; inspect hydration errors separately.
- A warm request reaches the expected service and port. A dormant canary wakes successfully over
  the HTTP/HTTPS protocols you serve. Sibling services do not share the wrong endpoint.
- Actual Nomad counts are acceptable. Proxy restart/discovery refresh preserves a running count.
- A long HTTP response and WebSocket remain functional and tracked across more than 30 seconds.
  Verify shared request visibility from another proxy before testing reductions.
- Redis has the effective `noeviction` policy and adequate headroom. Metrics have samples for each
  proxy/service; histogram-based aggregate p95 works before latency/error-driven reductions are enabled.

Enable a bounded policy on one canary group only after the compatibility checks. Apply the same
policy to every service in that group; choose a conservative `max_count`, and use `scale_to_zero: false`
if the canary must stay running. `enabled: false` is not a global pause of all scaling controllers.
Never configure an external autoscaler to own the same group concurrently.

Observe load-driven growth, reduction within bounds, cooldowns, and absent-metrics behavior. Local
latency/error signals alone can increase capacity but cannot authorize reductions. After an adequate
observation window, reopen traffic and expand policies gradually. Re-enable deployment automation
only after it points to the reviewed target revision and intended replica count.

## 6. Rollback

Rollback is a second maintenance cutover, not just `helm rollback`:

1. Stop new admissions and admin/job writers; drain or deliberately reconnect existing sessions.
2. Stop **every** new proxy/controller and keep automation paused. Save the current registry, job
   definitions, and counts for reconciliation; do not overwrite the pre-upgrade backup.
3. Restore the previous manifests, configuration, and pinned artifact with proxies still stopped.
   Keep stores on their existing endpoints unless a separately reviewed restore is required.
4. Reconcile the registry and Nomad workload state to the rollback plan. Old code may deserialize
   JSON with extra fields, but it does not enforce autoscaling bounds, understand composite group
   activity, or honor the new request coordination. Remove new-only policies/group mappings by
   restoring the reviewed pre-upgrade registry set. If jobs changed since the snapshot, merge those
   intended changes explicitly instead of blindly restoring stale registrations.
5. If durable mode is enabled, restore/reconcile **both** etcd and Redis consistently. Redis-only
   restore can be undone by etcd hydration. Do not flush a shared database, restore stale locks as
   live ownership, or delete request/lease keys while any nscale process is running. Allow expired
   coordination keys to age out after all writers stop.
6. Restore reviewed Nomad definitions/counts separately when needed: reverting an image does not
   undo Nomad submissions or autoscaling changes. Start only the previous version, validate its
   supported service topology, then reopen ingress and resume the old automation revision.

If new multi-group behavior is now required, reverting to a version without that behavior is not
a complete recovery plan. Prefer keeping maintenance enabled and repairing forward unless a tested
legacy-compatible topology is ready. The maintenance window and potential client reconnects must
be included in the rollback rehearsal.

## Completion record

Record the old/new artifact identifiers, backup locations, operator and timestamp, rendered config,
registration comparison, Nomad counts, Redis eviction/memory checks, metrics coverage, traffic tests,
and rollback rehearsal result. Link this record from the release decision. Local unit/integration
passes are supporting evidence, not proof that this deployment has completed migration.
