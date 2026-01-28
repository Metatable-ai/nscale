# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Enhanced README.md with open source best practices
- Created CONTRIBUTING.md with comprehensive contribution guidelines
- Added RELEASE.md with release process documentation
- Added CHANGELOG.md for tracking changes

### Changed

### Deprecated

### Removed

### Fixed

### Security

---

<!-- Template for first release - update date and details when creating v0.1.0 -->
## [0.1.0] - YYYY-MM-DD

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

### Components
- **traefik-plugin/**: ScaleWaker Traefik middleware (Go module)
- **idle-scaler/**: Idle scaler agent binary
- **activity-store/**: Shared store library for Consul KV and Redis

[Unreleased]: https://github.com/Metatable-ai/nomad_scale_to_zero/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Metatable-ai/nomad_scale_to_zero/releases/tag/v0.1.0
