<!--
// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0
-->

# Release Guide

This document describes what should be included in a release of Nomad Scale-to-Zero and the process for creating releases.

## 📦 What Should Be in a Release

A complete release of Nomad Scale-to-Zero should include:

### 1. Release Artifacts

#### Binary Releases
- **idle-scaler** binary for multiple platforms:
  - `idle-scaler-linux-amd64`
  - `idle-scaler-linux-arm64`
  - `idle-scaler-darwin-amd64` (macOS Intel)
  - `idle-scaler-darwin-arm64` (macOS Apple Silicon)
  - `idle-scaler-windows-amd64.exe`

#### Source Code
- Tagged source code (GitHub automatically creates these)
- `source.tar.gz`
- `source.zip`

#### Traefik Plugin
The Traefik plugin is distributed via Go modules and doesn't need separate binaries. Users reference it in their Traefik configuration:
```yaml
experimental:
  plugins:
    scalewaker:
      moduleName: "github.com/Metatable-ai/nomad_scale_to_zero/traefik-plugin"
      version: "v0.1.0"  # The release tag
```

### 2. Documentation

Each release should include:

- **Release Notes** - Summary of changes, new features, bug fixes, breaking changes
- **CHANGELOG.md** - Detailed list of all changes since the last release
- **Upgrade Guide** - If there are breaking changes or migration steps
- **Updated README.md** - Ensure version numbers and examples are current

### 3. Version Information

Update version references in:
- README.md (installation examples)
- go.mod files (if needed)
- Sample job files and configurations

## 🏷️ Version Numbering

This project follows [Semantic Versioning](https://semver.org/):

- **MAJOR.MINOR.PATCH** (e.g., `v1.2.3`)
  - **MAJOR**: Breaking changes or major rewrites
  - **MINOR**: New features, backward compatible
  - **PATCH**: Bug fixes, backward compatible

### Version Examples

- `v0.1.0` - Initial public release
- `v0.2.0` - Add Redis support (new feature)
- `v0.2.1` - Fix idle timeout bug (bug fix)
- `v1.0.0` - First stable release (API stability commitment)

## ✅ Pre-Release Checklist

Before creating a release, ensure:

### Code Quality
- [ ] All tests pass: `cd idle-scaler && go test ./...`
- [ ] All tests pass: `cd traefik-plugin && go test ./...`
- [ ] All tests pass: `cd activity-store && go test ./...`
- [ ] Code is formatted: `go fmt ./...`
- [ ] No linting errors: `go vet ./...` or `golangci-lint run`
- [ ] Dependencies are up to date: `go mod tidy`

### Documentation
- [ ] README.md is current and accurate
- [ ] CHANGELOG.md is updated with all changes
- [ ] Code examples work with the new version
- [ ] LOCAL_TESTING.md reflects any new setup requirements
- [ ] API documentation is updated (if applicable)

### Functionality
- [ ] Local test environment works: `./local-test/scripts/start-local-with-acl.sh`
- [ ] Sample jobs deploy successfully
- [ ] Scale-to-zero lifecycle works (scale down → wake up)
- [ ] Dead job revival works
- [ ] ACL integration works
- [ ] Both Consul KV and Redis backends work

### Security
- [ ] No known security vulnerabilities in dependencies
- [ ] ACL tokens and secrets are not hardcoded
- [ ] Run security scan: `go list -json -m all | nancy sleuth` (if nancy is installed)

## 🚀 Release Process

### 1. Prepare the Release

```bash
# 1. Ensure you're on main branch with latest changes
git checkout main
git pull origin main

# 2. Update CHANGELOG.md
# Add a new section for this version with all changes

# 3. Update version references in documentation
# - README.md examples
# - Any hardcoded version strings

# 4. Run tests
cd idle-scaler && go test ./... && cd ..
cd traefik-plugin && go test ./... && cd ..
cd activity-store && go test ./... && cd ..

# 5. Commit changes
git add CHANGELOG.md README.md
git commit -m "chore: prepare release v0.1.0"
git push origin main
```

### 2. Create Git Tag

```bash
# Create annotated tag
git tag -a v0.1.0 -m "Release v0.1.0

Major features:
- Scale-to-zero for Nomad workloads
- Traefik middleware plugin (ScaleWaker)
- Idle-scaler agent
- Consul KV and Redis backend support
- ACL integration
- Dead job revival"

# Push tag to GitHub
git push origin v0.1.0
```

### 3. Build Release Binaries

**Option A: Use the build script (recommended)**

```bash
./build-release.sh v0.1.0
```

**Option B: Manual build**

```bash
# Build idle-scaler for multiple platforms
cd idle-scaler

# Set version for embedding
VERSION=v0.1.0

# Linux AMD64
GOOS=linux GOARCH=amd64 go build -ldflags="-s -w -X main.version=${VERSION}" -o ../release/idle-scaler-linux-amd64 .

# Linux ARM64
GOOS=linux GOARCH=arm64 go build -ldflags="-s -w -X main.version=${VERSION}" -o ../release/idle-scaler-linux-arm64 .

# macOS AMD64 (Intel)
GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w -X main.version=${VERSION}" -o ../release/idle-scaler-darwin-amd64 .

# macOS ARM64 (Apple Silicon)
GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w -X main.version=${VERSION}" -o ../release/idle-scaler-darwin-arm64 .

# Windows AMD64
GOOS=windows GOARCH=amd64 go build -ldflags="-s -w -X main.version=${VERSION}" -o ../release/idle-scaler-windows-amd64.exe .

cd ..
```

**Note**: The `-ldflags` include:
- `-s -w`: Strip debug info to reduce binary size
- `-X main.version=${VERSION}`: Embed version string in the binary

### 4. Create GitHub Release

1. Go to https://github.com/Metatable-ai/nomad_scale_to_zero/releases
2. Click "Draft a new release"
3. Select the tag you created (e.g., `v0.1.0`)
4. Set release title: `v0.1.0 - Initial Release`
5. Add release notes (see template below)
6. Upload binary artifacts:
   - `idle-scaler-linux-amd64`
   - `idle-scaler-linux-arm64`
   - `idle-scaler-darwin-amd64`
   - `idle-scaler-darwin-arm64`
   - `idle-scaler-windows-amd64.exe`
7. Check "Set as the latest release" (if appropriate)
8. Click "Publish release"

### 5. Release Notes Template

```markdown
## Nomad Scale-to-Zero v0.1.0

### 🎉 Highlights

Brief description of major features or changes in this release.

### ✨ New Features

- Feature 1: Description
- Feature 2: Description

### 🐛 Bug Fixes

- Fix 1: Description
- Fix 2: Description

### 🔄 Changes

- Change 1: Description
- Change 2: Description

### ⚠️ Breaking Changes

List any breaking changes and migration instructions.

### 📦 Installation

#### Traefik Plugin

Add to your Traefik configuration:

```yaml
experimental:
  plugins:
    scalewaker:
      moduleName: "github.com/Metatable-ai/nomad_scale_to_zero/traefik-plugin"
      version: "v0.1.0"
```

#### Idle-Scaler Binary

Download the appropriate binary for your platform:

- Linux AMD64: `idle-scaler-linux-amd64`
- Linux ARM64: `idle-scaler-linux-arm64`
- macOS Intel: `idle-scaler-darwin-amd64`
- macOS Apple Silicon: `idle-scaler-darwin-arm64`
- Windows: `idle-scaler-windows-amd64.exe`

```bash
# Example: Download and run on Linux
wget https://github.com/Metatable-ai/nomad_scale_to_zero/releases/download/v0.1.0/idle-scaler-linux-amd64
chmod +x idle-scaler-linux-amd64
./idle-scaler-linux-amd64 --help
```

### 📚 Documentation

- [README.md](https://github.com/Metatable-ai/nomad_scale_to_zero/blob/v0.1.0/README.md)
- [LOCAL_TESTING.md](https://github.com/Metatable-ai/nomad_scale_to_zero/blob/v0.1.0/LOCAL_TESTING.md)
- [CONTRIBUTING.md](https://github.com/Metatable-ai/nomad_scale_to_zero/blob/v0.1.0/CONTRIBUTING.md)

### 🙏 Contributors

Thank all contributors for this release.

**Full Changelog**: https://github.com/Metatable-ai/nomad_scale_to_zero/compare/v0.0.0...v0.1.0
```

## 📝 Post-Release Tasks

After publishing a release:

### 1. Announce the Release

- [ ] Update GitHub repository description if needed
- [ ] Post announcement in project discussions
- [ ] Share on relevant community channels (if applicable)
- [ ] Update any external documentation or wikis

### 2. Verify Release

- [ ] Test downloading binaries from GitHub releases
- [ ] Verify Traefik can pull the plugin from the tagged version
- [ ] Check that documentation links work
- [ ] Verify installation instructions are accurate

### 3. Monitor for Issues

- [ ] Watch for bug reports related to the new release
- [ ] Be prepared to create a patch release if critical bugs are found
- [ ] Update documentation if common issues are discovered

## 🔧 Automation Ideas

To streamline future releases, consider:

### GitHub Actions Workflow

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Set up Go
        uses: actions/setup-go@v4
        with:
          go-version: '1.25'
      
      - name: Build binaries
        run: |
          cd idle-scaler
          
          # Linux
          GOOS=linux GOARCH=amd64 go build -o ../idle-scaler-linux-amd64 .
          GOOS=linux GOARCH=arm64 go build -o ../idle-scaler-linux-arm64 .
          
          # macOS
          GOOS=darwin GOARCH=amd64 go build -o ../idle-scaler-darwin-amd64 .
          GOOS=darwin GOARCH=arm64 go build -o ../idle-scaler-darwin-arm64 .
          
          # Windows
          GOOS=windows GOARCH=amd64 go build -o ../idle-scaler-windows-amd64.exe .
      
      - name: Create Release
        uses: softprops/action-gh-release@v1
        with:
          files: |
            idle-scaler-*
          draft: true
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### GoReleaser

Alternatively, use [GoReleaser](https://goreleaser.com/) for a more complete solution:

```yaml
# .goreleaser.yml
project_name: nomad-scale-to-zero

builds:
  - id: idle-scaler
    main: ./idle-scaler
    binary: idle-scaler
    goos:
      - linux
      - darwin
      - windows
    goarch:
      - amd64
      - arm64
    ignore:
      - goos: windows
        goarch: arm64

archives:
  - format: tar.gz
    name_template: >-
      {{ .ProjectName }}_
      {{- .Version }}_
      {{- .Os }}_
      {{- .Arch }}
    format_overrides:
      - goos: windows
        format: zip

checksum:
  name_template: 'checksums.txt'

release:
  draft: true
  prerelease: auto
```

## 📚 Additional Resources

- [Semantic Versioning](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [GitHub Releases Documentation](https://docs.github.com/en/repositories/releasing-projects-on-github)
- [GoReleaser Documentation](https://goreleaser.com/)
- [Writing Good Release Notes](https://blog.github.com/2013-01-09-release-your-software/)

---

**Questions?** See [CONTRIBUTING.md](CONTRIBUTING.md) or open a [discussion](https://github.com/Metatable-ai/nomad_scale_to_zero/discussions).
