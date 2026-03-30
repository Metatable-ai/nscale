<!--
// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0
-->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

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

[Unreleased]: https://github.com/Metatable-ai/nscale/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/Metatable-ai/nscale/releases/tag/v2.0.0
[0.1.0]: https://github.com/Metatable-ai/nscale/releases/tag/v0.1.0
