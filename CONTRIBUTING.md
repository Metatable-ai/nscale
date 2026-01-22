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
  - Go version (if building from source)
  - Operating system
  - Storage backend (Consul KV or Redis)
- **Configuration** - Relevant configuration snippets (sanitize any secrets!)
- **Logs** - Relevant log output from Traefik, idle-scaler, or Nomad
- **Screenshots** - If applicable, add screenshots to help explain your problem

**Example Bug Report:**

```markdown
## Bug: Service doesn't wake after scaling to zero

**Environment:**
- Nomad: v1.6.2
- Consul: v1.16.1
- Traefik: v2.10.4
- Storage: Redis 7.0

**Steps to Reproduce:**
1. Deploy job with scale-to-zero enabled
2. Scale to 0: `nomad job scale my-job main 0`
3. Make request: `curl -H 'Host: my-job.localhost' http://localhost/`

**Expected:** Service wakes up and responds
**Actual:** Request times out after 30s

**Logs:**
[Attach relevant Traefik/idle-scaler logs]
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

- **Go 1.25+** - [Install Go](https://go.dev/doc/install)
- **Nomad** - [Install Nomad](https://www.nomadproject.io/downloads)
- **Consul** - [Install Consul](https://www.consul.io/downloads)
- **Traefik** - [Install Traefik](https://doc.traefik.io/traefik/getting-started/install-traefik/)
- **Docker** (optional) - For running sample jobs
- **Redis** (optional) - For Redis backend testing

### Local Development Environment

The easiest way to get started is with our all-in-one local test script:

```bash
# Clone the repository
git clone https://github.com/Metatable-ai/nomad_scale_to_zero.git
cd nomad_scale_to_zero

# Run the local development environment
./local-test/scripts/start-local-with-acl.sh
```

This starts Nomad, Consul, Traefik, and the idle-scaler with ACLs enabled.

**For detailed development setup, see [LOCAL_TESTING.md](LOCAL_TESTING.md).**

### Building Components

```bash
# Build the idle-scaler
cd idle-scaler
go build -o idle-scaler .

# Build/test the Traefik plugin
cd traefik-plugin
go build .
go test ./...

# Build the activity-store library
cd activity-store
go test ./...
```

### Running Tests

```bash
# Run all tests
cd idle-scaler && go test ./...
cd traefik-plugin && go test ./...
cd activity-store && go test ./...

# Run tests with coverage
go test -v -cover ./...

# Run tests with race detection
go test -race ./...
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
   - Run the test suite: `go test ./...`
   - Test locally with the development environment
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

### Go Code Style

We follow standard Go conventions:

- **Use `gofmt`** - All code must be formatted with `gofmt`
- **Use `go vet`** - Check for common mistakes
- **Follow Go idioms** - Write idiomatic Go code
- **Keep it simple** - Prefer clarity over cleverness

```bash
# Format your code
gofmt -s -w .

# Check for issues
go vet ./...

# Run linters (optional but recommended)
golangci-lint run
```

### Code Organization

- **One logical change per commit** - Don't mix unrelated changes
- **Keep functions focused** - Each function should do one thing well
- **Document exported functions** - Use Go doc comments
- **Use meaningful names** - Variable and function names should be descriptive

### Comments

- Write comments for **why**, not **what**
- Document all exported types, functions, and constants
- Use complete sentences in comments
- Keep comments up-to-date with code changes

### Error Handling

- Always check errors - Never ignore returned errors
- Provide context - Wrap errors with additional context
- Use meaningful error messages

```go
// Good
if err != nil {
    return fmt.Errorf("failed to scale job %s: %w", jobID, err)
}

// Bad
if err != nil {
    return err
}
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

```go
// Format: TestFunctionName_Scenario_ExpectedBehavior
func TestScaleJob_WhenScaledToZero_ShouldStartAllocation(t *testing.T) {
    // Test implementation
}
```

### Integration Testing

Before submitting a PR, test your changes in a local environment:

1. Start the local test environment
2. Deploy sample jobs
3. Test the scale-to-zero lifecycle
4. Verify logs and metrics

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
- 📖 **Documentation**: Check [LOCAL_TESTING.md](LOCAL_TESTING.md) and component READMEs
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
