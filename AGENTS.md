## Purpose

This file gives repository-specific instructions to coding agents working in `nomad_scale_to_zero`.

The project is a Rust workspace for **nscale**, a Nomad scale-to-zero proxy that sits between Traefik and Nomad/Consul/Redis. Prefer small, verifiable changes that preserve existing crate boundaries and operational behavior.

## Rust development expectations

When editing Rust code in this repository:

- Prefer **idiomatic Rust** over clever shortcuts.
- Keep modules focused and preserve the current crate split instead of moving logic around unless the task requires it.
- Prefer strong typing and existing domain types from `nscale-core` such as `JobId`, `ServiceName`, `Endpoint`, and `JobRegistration` instead of passing raw strings everywhere.
- Reuse shared traits and abstractions from `nscale-core::traits` when adding behavior that crosses crate boundaries.
- In library code, prefer returning `Result` and `NscaleError` variants over panicking. Reserve `expect`/`unwrap` for startup-time invariants or truly unrecoverable situations.
- Use structured logging with `tracing`; avoid `println!`/`eprintln!` in normal code paths.
- Preserve async correctness: avoid blocking work in async contexts, respect cancellation/shutdown flow, and keep time-based behavior expressed through config-backed `Duration` helpers when possible.
- Keep serialization/config naming consistent with existing `serde` and Figment patterns.
- Avoid broad refactors unrelated to the task. This repo benefits from surgical changes.

## Required validation workflow

For Rust validation, use these commands by default:

1. `cargo fmt --all`
2. `cargo check --workspace`
3. `cargo clippy --workspace --all-targets -- -D warnings`
4. `cargo nextest run --workspace`

### Testing rule

**Do not default to `cargo test` in this repository.**

Use **`cargo nextest`** as the standard Rust test runner unless the user explicitly asks for `cargo test` or a crate requires a special command for a specific reason.

Preferred examples:

- Whole workspace: `cargo nextest run --workspace`
- Single crate: `cargo nextest run -p nscale-core`
- Single test binary / filtered run: `cargo nextest run -p nscale-core <filter>`

If you add or change tests, run the narrowest relevant `cargo nextest` command first, then expand to the broader workspace command if the change is cross-cutting.

## Configuration rules

- Runtime config is loaded from defaults, then `config/default.toml`, then `NSCALE_*` environment variables.
- Nested environment variables use **double underscores** because Figment is configured with `.split("__")`.
	- Example: `NSCALE_NOMAD__TOKEN`
	- Example: `NSCALE_CONSUL__TOKEN`
- Keep config changes aligned between root `config/default.toml` and `integration/config/default.toml` when the integration environment depends on the same setting.

## Codebase map: what lives where

### Root

- `Cargo.toml` — workspace definition, shared dependencies, and the `nscale` binary package.
- `src/main.rs` — application entrypoint; wires together config, Redis-backed state, Nomad and Consul clients, wake coordination, scale-down controller, proxy router, and admin routes.
- `config/default.toml` — default local/runtime configuration.
- `Dockerfile` — container build for the Rust binary.
- `README.md` — architecture, configuration, and operator-facing usage documentation.

### Workspace crates

#### `crates/nscale-core`

Shared domain and cross-crate foundations.

- `src/config.rs` — typed config structs and Figment loading.
- `src/error.rs` — shared `NscaleError` and `Result<T>`.
- `src/job.rs` — domain models like `JobId`, `ServiceName`, `Endpoint`, `JobRegistration`, and `JobState`.
- `src/traits.rs` — core abstractions for orchestrator, service discovery, and activity storage.

Put shared types and interfaces here when multiple crates depend on them.

#### `crates/nscale-nomad`

Nomad-facing client logic.

- `src/client.rs` — main Nomad API client implementation.
- `src/events.rs` — Nomad event handling/stream-related logic.
- `src/models.rs` — Nomad API payload/response types.

Changes here usually affect wake-up and scale-down behavior.

#### `crates/nscale-consul`

Consul integration and service discovery.

- `src/client.rs` — base Consul client.
- `src/catalog.rs` — catalog/service lookup logic.
- `src/health.rs` — health-check and readiness related logic.
- `src/traits_impl.rs` — implementations of shared traits against Consul.

#### `crates/nscale-store`

Redis-backed persistence and coordination.

- `src/activity.rs` — activity tracking used for idle detection.
- `src/lock.rs` — distributed locking helpers.
- `src/registry.rs` — job registration storage and lookup.

This crate is central to readiness checks and scale-down coordination.

#### `crates/nscale-proxy`

HTTP request handling for wake-on-request behavior.

- `src/handler.rs` — request entrypoint and app state for proxying.
- `src/middleware.rs` — middleware such as activity recording.
- `src/proxy.rs` — reverse-proxy behavior and upstream request flow.

If a request-path bug appears at the edge, start here.

#### `crates/nscale-waker`

Wake orchestration and in-memory job state transitions.

- `src/coordinator.rs` — wake coordinator and request coalescing.
- `src/state.rs` — internal state handling for wake lifecycle.

This crate owns the dormant → waking → ready transitions.

#### `crates/nscale-scaler`

Scale-to-zero control loop.

- `src/controller.rs` — scale-down controller and sweep logic.
- `src/traffic_probe.rs` — Traefik metrics probing to avoid scaling down active services.

Scale-down and traffic-aware decisions belong here.

### Integration and ops

- `integration/docker-compose.yml` — local integration stack.
- `integration/docker-compose.acl.yml` — ACL-enabled integration stack.
- `integration/config/default.toml` — integration-specific config values.
- `integration/jobs/` — sample Nomad job specs used for testing.
- `integration/k6/` — cold-start, load, storm, soak, and multi-service test scripts.
- `integration/test.sh` — main integration test entrypoint.
- `integration/test-acl.sh` — ACL integration test entrypoint.
- `integration/stress-test.sh` — heavier stress scenario.
- `integration/scripts/` — helper scripts for multi-job and environment setup.
- `integration/acl/` — ACL bootstrap scripts, policies, templates, and service startup helpers.
- `integration/traefik/` — Traefik static/dynamic config used by the local stack.

Use the `integration/` tree for end-to-end verification; do not mix those responsibilities into unit-test guidance.

## Editing guidance for agents

- Read the relevant crate and neighboring modules before editing.
- When changing behavior, keep the public interface stable unless the task explicitly requires an API change.
- Add or update tests near the affected crate/module.
- Mention which crates were touched and why in the final summary.
- If a task spans HTTP flow, wake coordination, and scale-down behavior, inspect `src/main.rs` first to understand how the pieces are wired together.

## Practical review heuristics

When investigating an issue, these are the usual starting points:

- Request handling problem → `crates/nscale-proxy`
- Wake-up / cold-start problem → `crates/nscale-waker` and `crates/nscale-nomad`
- Service discovery / health problem → `crates/nscale-consul`
- Idle detection / Redis / registry problem → `crates/nscale-store`
- Unexpected scale-down behavior → `crates/nscale-scaler`
- Config/env mismatch → `crates/nscale-core/src/config.rs` plus `config/default.toml` and `integration/config/default.toml`

## Generated files

- `target/` is generated build output. Do not edit files there.
