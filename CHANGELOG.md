<!--
// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0
-->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Planned release: **3.0.0**.

### Added
- Per-job autoscaling policies for running task-group capacity, with request-rate, latency, and error signals, shared cooldowns, and `/admin/autoscaling` status.
- Per-service round-robin endpoint pools, minimum-count cold wakes, independent multi-group scaling, and aggregate Prometheus latency histograms.
- Shared Redis request leases covering HTTP bodies and WebSocket tunnels, plus renewable job-mutation coordination and Nomad index checks.

### Changed
- Aligned all Cargo packages and Helm chart/app versions at `3.0.0`.
- Helm app deployments use `Recreate`; bundled Redis uses `noeviction` with additional memory headroom. Added values for endpoint refresh, Prometheus, missing-job cleanup, and a separate existing Secret for admin authentication.
- Successful `/admin/jobs` submissions replace the job’s managed service set in Redis and optional etcd, removing obsolete services and policies. Busy submissions return `409`; accepted Nomad jobs with failed registration replacement return `207` and require retry.
- Incomplete metrics prevent capacity reductions. Replica-local latency/error samples can trigger scale-up but cannot independently authorize downscaling.
- Wake deadlines include queue time; concurrent failing requests share a health attempt and later requests may retry.

### Fixed
- Preserve running counts after proxy restarts and allocation-stop events, isolate sibling-service health failures, and preserve endpoint rotation across refreshes.
- Resolve proxy services by exact identity, aggregate sibling metrics without double-counting router/service traffic, and retain partial overload observations.
- Preserve headers and request identity on empty-body GET/HEAD transport retries; retain request tracking for WebSocket tunnels and response streams.

### Deployment notes
- Follow the [2.2.x migration guide](docs/migration-autoscaling.md). Replace inherited/custom Redis `allkeys-lru` settings with the new `noeviction` default, pin the target image, and reconcile legacy multi-group registrations before reopening traffic.
- Drain and replace older proxy replicas together; mixed versions do not share all coordination guarantees.
- See [release readiness](docs/autoscaling-release-readiness.md) for test evidence, partial-submission recovery, operational limits, and remaining production gates.

---

## [2.2.1] - 2026-05-21

### Added
- Added `DELETE /admin/jobs/{job_id}` so operators can stop, purge, and deregister a managed Nomad job from nscale, with `force=true` support for explicit destructive cleanup.
- Added shared Redis-backed missing-job tracking plus `scaling.auto_deregister` / `NSCALE_SCALING__AUTO_DEREGISTER__*` configuration so stale registrations can be automatically forgotten after repeated Nomad `job not found` responses.
- Added end-to-end coverage for the new deregistration flows in `integration/test.sh` and `integration/test-durable-multi-replica.sh`, including in-flight purge protection and shared multi-replica threshold handling.

### Fixed
- Fixed admin API startup on current `axum` routing by using `{job_id}` path capture syntax instead of the removed `:job_id` segment style.
- Fixed wake-path error propagation so `JobNotFound` reaches the proxy/scaler cleanup logic instead of being flattened into a generic wake failure.
- Fixed durable multi-replica stale-registration cleanup so the shared auto-deregister threshold now returns `404` and removes the registration from both Redis and etcd.
- Improved Nomad deployment waiting in the integration harnesses so transient active-deployment scale conflicts do not make the end-to-end tests flaky.

---

## [2.2.0] - 2026-05-06

### Added
- Added HTTPS support in the local Traefik integration and hybrid Kubernetes stacks by exposing `:443`, loading a local self-signed certificate for `localhost` / `*.localhost`, and adding TLS-aware fallback routers so dormant services can still wake on HTTPS requests.
- Added HTTPS coverage to the end-to-end integration scripts (`integration/test.sh`, `integration/test-acl.sh`, and `nscale-kubernetes/test-hybrid.sh`) so both warm-path routing and cold-start wake-up are exercised over TLS.
- Added an etcd-backed durable registry mode with a new `nscale-etcd` crate so `JobRegistration` data can survive Redis cache loss and be shared across replicas.
- Added durable-registry integration coverage with `integration/docker-compose.durable.yml`, `integration/test-durable.sh`, and `integration/test-durable-multi-replica.sh` to verify Redis cache recovery and multi-replica read-through behavior.
- Added operator documentation for durable registry mode in `docs/durable-registry.md`, plus index references from `docs/README.md`, `README.md`, and related operator guides.

### Changed
- Updated the sample submit fixtures and echo job fixtures to advertise `entryPoints=http,https` with `tls=true`, matching production-style Traefik job tags while still routing through `s2z-nscale@file`.
- Updated the configuration surface with `[default.registry]` / `NSCALE_REGISTRY__*` settings for durable-registry enablement, etcd endpoints, key prefix, and reserved watch backoff wiring.
- Updated Docker and release build dependencies to install `protobuf-compiler`, which is required by the new etcd client build chain.
- Updated the README project structure and operator documentation to describe Redis as a cache layer and etcd as the durable registration source of truth when durable mode is enabled.

### Deprecated

### Removed

### Fixed
- Fixed the cold HTTPS path where Traefik previously returned `404` for dormant services because the file-provider fallback route only existed on the plain `http` entrypoint.
- Fixed registry recovery after Redis cache loss by reading through to etcd, repopulating Redis automatically, and preserving service-name-based lookup across replicas.
- Improved durable-registry startup validation and deregistration error handling when etcd endpoint configuration is empty or cache eviction fails mid-update.

### Security

---

## [2.1.0] - 2026-04-20

### Added
- Added `POST /admin/jobs`, allowing `nscale` to parse Nomad HCL with optional variables, inject the Traefik file-provider routing override, submit the job to Nomad, auto-register managed services, and seed activity in one step.
- Added `routing.file_provider_service` / `NSCALE_ROUTING__FILE_PROVIDER_SERVICE` so the injected Traefik service target is configurable without depending on optional Traefik metrics settings.
- Added integration coverage for the admin submission flow in `integration/test.sh`, `integration/test-acl.sh`, and `nscale-kubernetes/test-hybrid.sh`, plus dedicated submit fixtures for both environments.
- Added operator documentation for the admin submission flow in `docs/job-submission.md` and reflected the new workflow in the root `README.md`.

### Changed
- Updated the job registry path to support both job-id and service-name based lookup so submitted services keep working when `service_name` differs from the Nomad job ID.
- Updated the README quick-start and admin API documentation to treat `/admin/jobs` as the preferred submission path and `/admin/registry` as the manual fallback.

### Fixed
- Fixed automatic tag injection coverage for variableized submit fixtures by keeping Nomad block labels literal while still supporting variables inside the job body.

---

## [2.0.0] - 2026-03-30

### Added
- Rewrote nscale as a Rust workspace with `nscale-core`, `nscale-nomad`, `nscale-consul`, `nscale-store`, `nscale-proxy`, `nscale-waker`, and `nscale-scaler` crates plus a unified `nscale` binary.
- Added full-path interception through Traefik so both cold and warm traffic flows through nscale.
- Added `InFlightTracker` protection with RAII guards and heartbeat refreshes to keep long-running requests alive across idle windows.
- Added an integrated scale-down controller with Redis-backed activity tracking, traffic probing, Nomad event stream handling, Redis Pub/Sub, and bounded Nomad concurrency.
- Added ACL-aware local integration environments, sample jobs, and end-to-end stress coverage for coldstart, load, storm, soak, multi-service, long-work, and endurance scenarios.
- Added automated release packaging for cross-platform Rust binaries and GitHub release assets.

### Changed
- Replaced the earlier Go-based components with a single Rust implementation and updated the repository layout around the new workspace.
- Updated Traefik routing so nscale remains in the path for both wake-on-request and steady-state proxying.
- Improved wake handling with endpoint caching, cache invalidation, and wake reassertion when upstream endpoints become stale.
- Consolidated configuration, Docker packaging, and testing documentation around the Rust-based deployment and integration stack.

### Fixed
- Long-running requests are no longer interrupted by idle scale-down while they are still in flight.
- Scale-down decisions now respect in-flight guards and traffic checks before terminating a job.
- Wake paths recover cleanly from stale cached endpoints instead of staying pinned to dead backends.

### Removed
- Retired the legacy Go-based `traefik-plugin`, `idle-scaler`, and `activity-store` implementation paths in favor of the Rust workspace.
- Replaced the older `local-test/` scaffolding with the `integration/` harness and ACL-capable compose setup.

---

## [0.1.0] - 2026-01-28

### Added
- Initial public release
- Scale-to-zero functionality for HashiCorp Nomad workloads
- Traefik middleware plugin (ScaleWaker) for automatic wake-on-request
- Idle-scaler agent for automatic scale-down after idle timeout
- Activity store abstraction with Consul KV and Redis backends
- Dead job revival functionality
- First-class ACL support for Nomad and Consul
- Comprehensive local testing environment with ACL support
- Sample job files and configurations
- Documentation: README.md, LOCAL_TESTING.md, component READMEs
- CONTRIBUTING.md with comprehensive contribution guidelines
- RELEASE.md with release process documentation
- RELEASE_QUICK.md for quick release reference
- CHANGELOG.md for tracking changes
- build-release.sh script for building release binaries
- GitHub Actions workflow (.github/workflows/release.yml) for automated releases

### Components
- **traefik-plugin/**: ScaleWaker Traefik middleware (Go module)
- **idle-scaler/**: Idle scaler agent binary
- **activity-store/**: Shared store library for Consul KV and Redis

[Unreleased]: https://github.com/Metatable-ai/nscale/compare/v2.2.1...HEAD
[2.2.1]: https://github.com/Metatable-ai/nscale/releases/tag/v2.2.1
[2.2.0]: https://github.com/Metatable-ai/nscale/releases/tag/v2.2.0
[2.1.0]: https://github.com/Metatable-ai/nscale/releases/tag/v2.1.0
[2.0.0]: https://github.com/Metatable-ai/nscale/releases/tag/v2.0.0
[0.1.0]: https://github.com/Metatable-ai/nscale/releases/tag/v0.1.0
