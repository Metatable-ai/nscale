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

[Unreleased]: https://github.com/Metatable-ai/nomad_scale_to_zero/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Metatable-ai/nomad_scale_to_zero/releases/tag/v0.1.0
