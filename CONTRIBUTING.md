<!--
// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0
-->

# Contributing to Nomad Scale-to-Zero

👋 **Welcome!** Thank you for considering contributing to Nomad Scale-to-Zero! We're excited to have you join our community.

This document provides guidelines for contributing to this project. Following these guidelines helps maintainers and the community understand your contributions and respond efficiently.

## 📋 Table of Contents

- [Code of Conduct](#code-of-conduct)
- [How Can I Contribute?](#how-can-i-contribute)
  - [Reporting Bugs](#reporting-bugs)
  - [Suggesting Enhancements](#suggesting-enhancements)
  - [Your First Code Contribution](#your-first-code-contribution)
- [Development Setup](#development-setup)
- [Pull Request Process](#pull-request-process)
- [Code Style Guidelines](#code-style-guidelines)
- [Testing Requirements](#testing-requirements)
- [Commit Message Conventions](#commit-message-conventions)
- [Getting Help](#getting-help)
- [License](#license)

## Code of Conduct

This project follows a simple code of conduct: **Be kind, be respectful, and be collaborative.**

We are committed to providing a welcoming and inclusive environment for everyone. Examples of behavior that contributes to a positive environment:

- Using welcoming and inclusive language
- Being respectful of differing viewpoints and experiences
- Gracefully accepting constructive criticism
- Focusing on what is best for the community
- Showing empathy towards other community members

Examples of unacceptable behavior:

- Trolling, insulting/derogatory comments, and personal or political attacks
- Public or private harassment
- Publishing others' private information without explicit permission
- Other conduct which could reasonably be considered inappropriate in a professional setting

## How Can I Contribute?

### Reporting Bugs

Before creating a bug report, please check existing issues to avoid duplicates.

**When submitting a bug report, include:**

- **Clear, descriptive title** - Use a clear and descriptive title for the issue
- **Steps to reproduce** - Detailed steps to reproduce the problem
- **Expected behavior** - What you expected to happen
- **Actual behavior** - What actually happened
- **Environment details**:
  - Nomad version
  - Consul version
  - Traefik version
  - Rust version (if building from source)
  - Operating system
- **Configuration** - Relevant configuration snippets (sanitize any secrets!)
- **Logs** - Relevant log output from Traefik, nscale, or Nomad
- **Screenshots** - If applicable, add screenshots to help explain your problem

**Example Bug Report:**

```markdown
## Bug: Service doesn't wake after scaling to zero

**Environment:**
- Nomad: v1.10.5
- Consul: v1.22
- Traefik: v3.1
- Redis: 7.0
- Rust: 1.87+

**Steps to Reproduce:**
1. Deploy job with scale-to-zero enabled
2. Register with nscale: `curl -X POST http://localhost:9090/admin/registry ...`
3. Make request: `curl -H 'Host: my-job.localhost' http://localhost:8080/`

**Expected:** Service wakes up and responds
**Actual:** Request times out after 30s

**Logs:**
[Attach relevant Traefik/nscale logs]
```

### Suggesting Enhancements

Enhancement suggestions are welcome! Before creating an enhancement suggestion:

1. **Check the roadmap** in the README to see if it's already planned
2. **Search existing issues** to avoid duplicates
3. **Consider the scope** - Is this enhancement broadly useful?

**When submitting an enhancement, include:**

- **Clear use case** - Describe the problem you're trying to solve
- **Proposed solution** - How you envision the enhancement working
- **Alternatives considered** - What other solutions have you considered?
- **Impact** - Who would benefit from this enhancement?

### Your First Code Contribution

Unsure where to start? Look for issues labeled:

- `good first issue` - Good for newcomers
- `help wanted` - Extra attention needed
- `documentation` - Documentation improvements

**Not sure if your contribution is needed?** Open an issue first to discuss it!

## Development Setup

### Prerequisites

- **Rust 1.87+** - [Install Rust](https://rustup.rs/)
- **Docker & Docker Compose** - For the integration stack
- **Nomad 1.10+** - [Install Nomad](https://developer.hashicorp.com/nomad/install)
- **Consul 1.18+** - [Install Consul](https://developer.hashicorp.com/consul/install)
- **Redis 7+** - Used as activity store

### Local Development Environment

```bash
# Clone the repository
git clone https://github.com/Metatable-ai/nomad_scale_to_zero.git
cd nomad_scale_to_zero

# Start the integration stack (Nomad, Consul, Redis, Traefik, nscale)
cd integration
docker compose up -d
```

### Building

```bash
# Build the nscale binary
cargo build --release

# Build with Docker
docker build -t nscale .
```

### Running Tests

```bash
# Run all unit tests across the workspace
cargo test --workspace

# Run tests for a specific crate
cargo test -p nscale-nomad
cargo test -p nscale-waker

# Run with verbose output
cargo test --workspace -- --nocapture
```

### Integration / Stress Tests

```bash
cd integration

# Basic integration test
./test.sh

# Stress test with 50 services + chaos killing
./stress-test.sh
```

## Pull Request Process

1. **Fork the repository** and create your branch from `main`

   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes**
   - Keep changes focused and atomic
   - Add tests for new functionality
   - Update documentation as needed

3. **Test your changes**
   - Run the test suite: `cargo test --workspace`
   - Test locally with the integration stack
   - Ensure no existing functionality is broken

4. **Commit your changes**
   - Follow our [commit message conventions](#commit-message-conventions)
   - Use clear, descriptive commit messages

5. **Push to your fork**

   ```bash
   git push origin feature/your-feature-name
   ```

6. **Create a Pull Request**
   - Use a clear, descriptive title
   - Reference any related issues
   - Describe what changes you made and why
   - Include screenshots for UI changes
   - Fill out the PR template if provided

7. **Respond to feedback**
   - Address reviewer comments
   - Update your PR as needed
   - Be patient and respectful

### PR Review Process

- Maintainers will review your PR as soon as possible
- You may be asked to make changes or provide clarification
- Once approved, a maintainer will merge your PR
- Your contribution will be acknowledged in the release notes!

## Code Style Guidelines

### Rust Code Style

We follow standard Rust conventions:

- **Use `cargo fmt`** - All code must be formatted with rustfmt
- **Use `cargo clippy`** - Check for common mistakes and lints
- **Follow Rust idioms** - Write idiomatic Rust code
- **Keep it simple** - Prefer clarity over cleverness

```bash
# Format your code
cargo fmt --all

# Check for issues
cargo clippy --workspace -- -D warnings
```

### Code Organization

- **One logical change per commit** - Don't mix unrelated changes
- **Keep functions focused** - Each function should do one thing well
- **Document public items** - Use `///` doc comments on public types and functions
- **Use meaningful names** - Variable and function names should be descriptive

### Comments

- Write comments for **why**, not **what**
- Document all public types, functions, and constants with `///`
- Use complete sentences in comments
- Keep comments up-to-date with code changes

### Error Handling

- Use `Result<T, E>` for fallible operations
- Provide context with `.map_err()` or `anyhow::Context`
- Use meaningful error messages

```rust
// Good
let resp = client
    .post(&url)
    .json(&body)
    .send()
    .await
    .map_err(|e| anyhow!("failed to scale job {}: {}", job_id, e))?;

// Bad
let resp = client.post(&url).json(&body).send().await?;
```

## Testing Requirements

### When to Add Tests

- **All new features** must include tests
- **Bug fixes** should include a regression test
- **Refactoring** should maintain existing test coverage

### Test Coverage

- Aim for 80%+ test coverage for new code
- Critical paths should have 100% coverage
- Integration tests for end-to-end flows

### Test Naming

```rust
// Format: test_function_name_scenario_expected_behavior
#[tokio::test]
async fn test_scale_up_when_scaled_to_zero_should_start_allocation() {
    // Test implementation
}
```

### Integration Testing

Before submitting a PR, test your changes in the integration environment:

1. Start the integration stack: `cd integration && docker compose up -d`
2. Deploy sample jobs: `nomad job run integration/jobs/echo-s2z.nomad`
3. Register with nscale and test the wake/idle/scale-down lifecycle
4. Verify logs: `docker compose logs nscale`

## Commit Message Conventions

We use clear, descriptive commit messages that follow this format:

```
<type>: <subject>

<body>

<footer>
```

### Types

- **feat**: New feature
- **fix**: Bug fix
- **docs**: Documentation changes
- **style**: Code style changes (formatting, missing semicolons, etc.)
- **refactor**: Code refactoring without changing functionality
- **test**: Adding or updating tests
- **chore**: Maintenance tasks (dependencies, build, etc.)

### Examples

```
feat: add Redis support for activity store

- Implement RedisStore interface
- Add configuration for Redis connection
- Update documentation with Redis setup

Closes #123
```

```
fix: prevent panic when Consul is unreachable

Add proper error handling and retry logic when Consul
connection fails. Previously, the application would panic.

Fixes #456
```

```
docs: update LOCAL_TESTING.md with ACL setup

Add detailed steps for configuring Nomad and Consul ACLs
in the local development environment.
```

## Getting Help

Need assistance? We're here to help!

- 💬 **Questions**: Use [GitHub Discussions](https://github.com/Metatable-ai/nomad_scale_to_zero/discussions)
- 📖 **Documentation**: Check the [README](README.md) and crate-level docs
- 🐛 **Issues**: Search existing issues or create a new one
- 📧 **Direct Contact**: Reach out to maintainers via GitHub

**Don't hesitate to ask questions!** There are no "dumb" questions. We'd rather you ask than struggle in silence.

## License

By contributing to Nomad Scale-to-Zero, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).

When you submit code changes, your submissions are understood to be under the same Apache 2.0 License that covers the project. Feel free to contact the maintainers if that's a concern.

## Recognition

All contributors will be:
- Acknowledged in release notes
- Listed in the contributors section (if we add one)
- Appreciated and thanked by the community! 🎉

---

**Thank you for contributing to Nomad Scale-to-Zero!** Your efforts help make this project better for everyone. 🚀
