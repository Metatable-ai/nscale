# Nomad Scale-to-Zero (with Traefik)

Scale-to-zero allows Nomad services to be scaled down to **0 allocations when idle**, then automatically **woken up on the next request**.

This repo implements scale-to-zero using:

- **Traefik** as the ingress proxy
- a custom **Traefik middleware plugin** ("ScaleWaker") to wake services
- an **idle-scaler** agent to scale services back down after an idle timeout
- an **activity store** (Consul KV or Redis) to track last-seen request time and (optionally) store job specs for dead job revival

## How it works

### Request path (wake-up)

1. A request arrives at Traefik for `some-service.localhost`.
2. The **ScaleWaker middleware** determines the target service/job from the request (usually the `Host` header).
3. If the service is not healthy/registered (typically because it’s scaled to 0):
   - it calls the **Nomad API** to scale the job group up (usually to 1)
   - it waits for the service to become **healthy in Consul** (bounded by a timeout)
4. It records activity (last request timestamp) in the configured activity store.
5. The request is proxied to the now-running backend.

### Background path (scale-down)

1. The **idle-scaler** periodically scans for scale-to-zero-enabled jobs.
2. For each job it reads the last activity timestamp.
3. If `now - lastActivity > idleTimeout`, it scales the job group down to 0.

## Architecture notes (V2 configuration)

The project evolved from a “verbose tags everywhere” setup to a simpler **V2** configuration:

- **Infrastructure configuration** comes from environment variables (set once on Traefik / idle-scaler), instead of repeating addresses in every job.
- **Per-job configuration** in Traefik tags is minimal (usually only `serviceName` and `timeout`).
- **ACL support** is first-class:
  - Nomad API calls include `X-Nomad-Token`
  - Consul API calls include `X-Consul-Token`

### Core environment variables

Traefik plugin (ScaleWaker) reads:

- `S2Z_NOMAD_ADDR` (default: `http://nomad.service.consul:4646`)
- `S2Z_CONSUL_ADDR` (default: `http://consul.service.consul:8500`)
- `S2Z_NOMAD_TOKEN` (optional)
- `S2Z_CONSUL_TOKEN` (optional)
- `S2Z_ACTIVITY_STORE` (`consul` or `redis`)
- `S2Z_JOB_SPEC_STORE` (`consul` or `redis`)
- `S2Z_REDIS_ADDR`, `S2Z_REDIS_PASSWORD` (optional, if using Redis)

Idle-scaler uses:

- `NOMAD_ADDR`, `CONSUL_ADDR`
- `NOMAD_TOKEN`, `CONSUL_TOKEN` (optional)
- `IDLE_CHECK_INTERVAL`, `DEFAULT_IDLE_TIMEOUT`
- `STORE_TYPE` + Redis config when applicable

## Local development (recommended)

The quickest way to demo this to other developers is the single script:

- `local-test/scripts/start-local-with-acl.sh`

It will:

- start Consul + Nomad in dev mode **with ACLs enabled**
- create least-privilege tokens and export them
- start Traefik configured with the local plugin and Consul Catalog provider
- build the idle-scaler and run it as a Nomad system job (with tokens)

It prints dashboards and tails Traefik logs. Stop with Ctrl-C (the script traps and cleans up the spawned processes).

### Smoke test

After the local stack is up:

1. Submit a sample job (for example):

   - `nomad job run local-test/sample-jobs/echo-s2z.hcl`

2. Hit it through Traefik:

   - `curl -H 'Host: echo-s2z.localhost' http://localhost/`

3. Scale it down to 0:

   - `nomad job scale echo-s2z main 0`

4. Hit it again; it should wake back up:

   - `curl -H 'Host: echo-s2z.localhost' http://localhost/`

## ACL policies (local-test)

The policies used by the local ACL script live in `local-test/nomad/`:

- `scale-to-zero-policy.hcl` — Nomad policy for submitting/reading/scaling jobs
- `scale-to-zero-consul-policy.hcl` — Consul policy for KV writes and service discovery/cleanup
- `consul-catalog-read-policy.hcl` — Consul policy used by Traefik’s Consul Catalog provider
- `nomad-agent-consul-policy.hcl` — Consul policy used by the Nomad agent for service registration/deregistration

## Repository layout

- `traefik-plugin/` — ScaleWaker Traefik middleware plugin (Go)
- `idle-scaler/` — idle scaler agent (Go)
- `activity-store/` — shared store abstraction (Consul KV / Redis)
- `local-test/` — local configs and sample jobs
  - `local-test/scripts/start-local-with-acl.sh` — one-shot local demo with ACLs
  - `local-test/traefik/` — dynamic config (fallback router/middleware)
  - `local-test/sample-jobs/` — sample Nomad jobs with minimal V2 tags
  - `local-test/nomad/` — ACL policy HCLs for local testing

## Further reading

- `LOCAL_TESTING.md` — deeper local testing details
