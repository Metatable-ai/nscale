# Quick Release Guide

This is a condensed version of [RELEASE.md](RELEASE.md) for quick reference.

## Quick Steps for Creating a Release

### 1. Pre-Release Prep

```bash
# Ensure main branch is up to date
git checkout main
git pull origin main

# Update CHANGELOG.md with version and changes
# Update README.md if needed

# Run tests
cd idle-scaler && go test ./... && cd ..
cd traefik-plugin && go test ./... && cd ..
cd activity-store && go test ./... && cd ..

# Commit changes
git add CHANGELOG.md README.md
git commit -m "chore: prepare release v0.1.0"
git push origin main
```

### 2. Create and Push Tag

```bash
# Create annotated tag
git tag -a v0.1.0 -m "Release v0.1.0"

# Push tag (this triggers GitHub Actions workflow)
git push origin v0.1.0
```

### 3. GitHub Actions (Automatic)

When you push a tag, GitHub Actions will:
- Build binaries for all platforms
- Generate checksums
- Create a draft release on GitHub

### 4. Finalize Release on GitHub

1. Go to https://github.com/Metatable-ai/nomad_scale_to_zero/releases
2. Find the draft release
3. Edit release notes if needed
4. Publish the release

## Manual Build (if needed)

```bash
# Build all binaries
./build-release.sh v0.1.0

# Binaries will be in release/ directory
```

## What Gets Released

- ✅ **idle-scaler** binaries (Linux, macOS, Windows, AMD64 & ARM64)
- ✅ **traefik-plugin** (Go module, referenced by tag)
- ✅ Source code (automatic from tag)
- ✅ Checksums file
- ✅ Release notes

## Version Format

Use semantic versioning: `v{MAJOR}.{MINOR}.{PATCH}`

Examples:
- `v0.1.0` - First release
- `v0.2.0` - New feature
- `v0.2.1` - Bug fix
- `v1.0.0` - First stable release

## Need More Details?

See the complete [RELEASE.md](RELEASE.md) guide for:
- Detailed pre-release checklist
- Release notes template
- Post-release tasks
- Troubleshooting
