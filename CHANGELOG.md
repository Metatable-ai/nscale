<!--
// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0
-->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/Metatable-ai/nscale/compare/v2.2.0...HEAD
[2.2.0]: https://github.com/Metatable-ai/nscale/releases/tag/v2.2.0
[2.1.0]: https://github.com/Metatable-ai/nscale/releases/tag/v2.1.0
[2.0.0]: https://github.com/Metatable-ai/nscale/releases/tag/v2.0.0
[0.1.0]: https://github.com/Metatable-ai/nscale/releases/tag/v0.1.0
