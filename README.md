<!--
// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0
-->

# Nomad Scale-to-Zero

> **Automatic scale-to-zero for HashiCorp Nomad workloads with Traefik and wake-on-request**

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Go Version](https://img.shields.io/badge/Go-1.25%2B-00ADD8?logo=go)](https://go.dev/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

Scale-to-zero allows Nomad services to be scaled down to **0 allocations when idle**, then automatically **woken up on the next request**. This dramatically reduces infrastructure costs for services with intermittent or unpredictable traffic patterns while maintaining instant availability.

## ✨ Features

- **🚀 Automatic Wake-on-Request**: Services scale from 0 to N when traffic arrives via Traefik middleware
- **💤 Intelligent Idle Detection**: Configurable idle timeouts automatically scale down unused services
- **🔄 Dead Job Revival**: Automatically restore and start stopped/purged jobs on first request
- **🔐 ACL-Ready**: First-class support for Nomad and Consul ACLs with token management
- **📊 Flexible Storage**: Choose between Consul KV (simple) or Redis (high-performance) backends
- **⚡ Production-Ready**: Minimal configuration, battle-tested in production environments
- **🎯 Per-Service Configuration**: Fine-grained control via job metadata and Traefik tags

## 🏗️ Architecture

This implementation combines several components:

- **Traefik** as the ingress proxy
- **ScaleWaker** - a custom Traefik middleware plugin to wake services
- **idle-scaler** - an agent to scale services back down after idle timeout
- **activity-store** - Consul KV or Redis backend to track activity and store job specs

## 🚀 Quick Start

The fastest way to try scale-to-zero locally is with the all-in-one demo script:

```bash
./local-test/scripts/start-local-with-acl.sh
```

This script:
- Starts Consul + Nomad in dev mode **with ACLs enabled**
- Creates least-privilege tokens
- Starts Traefik with the ScaleWaker plugin
- Builds and runs the idle-scaler as a Nomad system job

### Simple Test

Once the stack is running:

```bash
# 1. Deploy a scale-to-zero enabled job
nomad job run local-test/sample-jobs/echo-s2z.hcl

# 2. Test the service
curl -H 'Host: echo-s2z.localhost' http://localhost/

# 3. Scale it down to 0
nomad job scale echo-s2z main 0

# 4. Hit it again - it wakes back up automatically!
curl -H 'Host: echo-s2z.localhost' http://localhost/
```

**See [LOCAL_TESTING.md](LOCAL_TESTING.md) for detailed development setup and testing guide.**

## 💡 Use Cases

Scale-to-zero is perfect for:

- **Development/Staging Environments**: Dramatically reduce costs for environments used only during business hours
- **Preview Environments**: PR previews and feature branches that sit idle most of the time
- **Batch Processing Services**: Jobs triggered by external events (webhooks, cron) with idle periods
- **Internal Tools**: Admin panels, dashboards, and utilities with sporadic usage
- **Microservices**: Low-traffic services in a microservices architecture
- **Multi-Tenant Applications**: Per-customer services that aren't always active

### Why Scale-to-Zero?

Traditional auto-scaling typically scales to a minimum of 1 instance, which still consumes resources 24/7. Scale-to-zero goes further:

- **Reduce costs by 90%+ for idle services**
- **Maintain instant availability** with automatic wake-on-request
- **Optimize resource utilization** across your cluster
- **Simplify operations** with automatic lifecycle management

## 📖 How it works

### Request path (wake-up)

1. A request arrives at Traefik for `some-service.localhost`.
2. The **ScaleWaker middleware** determines the target service/job from the request (usually the `Host` header).
3. If the service is not healthy/registered (typically because it’s scaled to 0):
   - it calls the **Nomad API** to scale the job group up (usually to 1)
   - it waits for the service to become **healthy in Consul** (bounded by a timeout)
4. It records activity (last request timestamp) in the configured activity store.
5. The request is proxied to the now-running backend.

### Background path (scale-down)

1. The **idle-scaler** periodically scans for scale-to-zero-enabled jobs.
2. For each job it reads the last activity timestamp.
3. If `now - lastActivity > idleTimeout`, it scales the job group down to 0.

## 🏭 Production Deployment

### Prerequisites

- HashiCorp Nomad cluster (1.0+)
- HashiCorp Consul cluster
- Traefik (2.9+) as ingress proxy
- Redis (optional, recommended for large deployments)

### Deployment Steps

1. **Deploy the Traefik Plugin**

   Install the ScaleWaker plugin on your Traefik instance:

   ```yaml
   experimental:
     plugins:
       scalewaker:
         moduleName: "github.com/Metatable-ai/nomad_scale_to_zero/traefik-plugin"
         version: "v0.1.0"  # Use latest release
   ```

   Configure environment variables:

   ```bash
   S2Z_NOMAD_ADDR=http://nomad.service.consul:4646
   S2Z_CONSUL_ADDR=http://consul.service.consul:8500
   S2Z_ACTIVITY_STORE=redis
   S2Z_REDIS_ADDR=redis.service.consul:6379
   S2Z_NOMAD_TOKEN=<your-nomad-token>
   S2Z_CONSUL_TOKEN=<your-consul-token>
   ```

2. **Deploy the Idle-Scaler**

   Run the idle-scaler as a Nomad system job:

   ```bash
   nomad job run local-test/system-jobs/idle-scaler.hcl
   ```

   Ensure environment variables are set with appropriate tokens.

3. **Configure Jobs for Scale-to-Zero**

   Add metadata to your job specifications:

   ```hcl
   job "my-service" {
     meta = {
       "scale-to-zero.enabled"      = "true"
       "scale-to-zero.idle-timeout" = "300"  # seconds
       "scale-to-zero.job-spec-kv"  = "scale-to-zero/jobs/my-service"
     }
     
     group "main" {
       # ... your group config
       
       service {
         tags = [
           "traefik.enable=true",
           "traefik.http.routers.myservice.rule=Host(`myservice.example.com`)",
           "traefik.http.middlewares.scalewaker-myservice.plugin.scalewaker.serviceName=my-service",
           "traefik.http.middlewares.scalewaker-myservice.plugin.scalewaker.timeout=30s",
           "traefik.http.routers.myservice.middlewares=scalewaker-myservice",
         ]
       }
     }
   }
   ```

### Production Best Practices

- **Use Redis for Storage**: For deployments with 50+ jobs, use Redis instead of Consul KV to reduce Raft pressure
- **Set Appropriate Timeouts**: Balance cold-start latency against resource savings
- **Monitor Wake Times**: Track how long services take to become healthy after wake-up
- **Use ACL Tokens**: Always use least-privilege tokens in production
- **Test Dead Job Revival**: Verify job specs are stored correctly and can be restored
- **Configure Health Checks**: Ensure services have proper health checks for reliable wake detection

### ACL Setup

Create dedicated policies for scale-to-zero components:

**Nomad Policy** (see `local-test/nomad/scale-to-zero-policy.hcl`):
```hcl
namespace "*" {
  policy = "write"
  capabilities = ["submit-job", "read-job", "scale-job"]
}
```

**Consul Policy** (see `local-test/nomad/scale-to-zero-consul-policy.hcl`):
```hcl
key_prefix "scale-to-zero/" {
  policy = "write"
}
service_prefix "" {
  policy = "write"
}
```

## 🏗️ Architecture Notes (V2 Configuration)

The project evolved from a “verbose tags everywhere” setup to a simpler **V2** configuration:

- **Infrastructure configuration** comes from environment variables (set once on Traefik / idle-scaler), instead of repeating addresses in every job.
- **Per-job configuration** in Traefik tags is minimal (usually only `serviceName` and `timeout`).
- **ACL support** is first-class:
  - Nomad API calls include `X-Nomad-Token`
  - Consul API calls include `X-Consul-Token`

### Core environment variables

Traefik plugin (ScaleWaker) reads:

- `S2Z_NOMAD_ADDR` (default: `http://nomad.service.consul:4646`)
- `S2Z_CONSUL_ADDR` (default: `http://consul.service.consul:8500`)
- `S2Z_NOMAD_TOKEN` (optional)
- `S2Z_CONSUL_TOKEN` (optional)
- `S2Z_ACTIVITY_STORE` (`consul` or `redis`)
- `S2Z_JOB_SPEC_STORE` (`consul` or `redis`)
- `S2Z_REDIS_ADDR`, `S2Z_REDIS_PASSWORD` (optional, if using Redis)

Idle-scaler uses:

- `NOMAD_ADDR`, `CONSUL_ADDR`
- `NOMAD_TOKEN`, `CONSUL_TOKEN` (optional)
- `IDLE_CHECK_INTERVAL`, `DEFAULT_IDLE_TIMEOUT`
- `STORE_TYPE` + Redis config when applicable

## Local development (recommended)

The quickest way to demo this to other developers is the single script:

- `local-test/scripts/start-local-with-acl.sh`

It will:

- start Consul + Nomad in dev mode **with ACLs enabled**
- create least-privilege tokens and export them
- start Traefik configured with the local plugin and Consul Catalog provider
- build the idle-scaler and run it as a Nomad system job (with tokens)

It prints dashboards and tails Traefik logs. Stop with Ctrl-C (the script traps and cleans up the spawned processes).

### Smoke test

After the local stack is up:

1. Submit a sample job (for example):

   - `nomad job run local-test/sample-jobs/echo-s2z.hcl`

2. Hit it through Traefik:

   - `curl -H 'Host: echo-s2z.localhost' http://localhost/`

3. Scale it down to 0:

   - `nomad job scale echo-s2z main 0`

4. Hit it again; it should wake back up:

   - `curl -H 'Host: echo-s2z.localhost' http://localhost/`

## ACL policies (local-test)

The policies used by the local ACL script live in `local-test/nomad/`:

- `scale-to-zero-policy.hcl` — Nomad policy for submitting/reading/scaling jobs
- `scale-to-zero-consul-policy.hcl` — Consul policy for KV writes and service discovery/cleanup
- `consul-catalog-read-policy.hcl` — Consul policy used by Traefik’s Consul Catalog provider
- `nomad-agent-consul-policy.hcl` — Consul policy used by the Nomad agent for service registration/deregistration

## 📦 Repository Layout

- **`traefik-plugin/`** — ScaleWaker Traefik middleware plugin (Go)
- **`idle-scaler/`** — Idle scaler agent (Go)
- **`activity-store/`** — Shared store abstraction (Consul KV / Redis)
- **`local-test/`** — Local development configs and sample jobs
  - `local-test/scripts/start-local-with-acl.sh` — One-shot local demo with ACLs
  - `local-test/traefik/` — Dynamic Traefik config (fallback router/middleware)
  - `local-test/sample-jobs/` — Sample Nomad jobs with minimal V2 tags
  - `local-test/nomad/` — ACL policy HCLs for local testing

## 🤝 Community & Support

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details on:

- How to report bugs and request features
- Development setup and testing
- Code style and conventions
- Pull request process

### Getting Help

- 📖 **Documentation**: Start with [LOCAL_TESTING.md](LOCAL_TESTING.md) for setup details
- 🐛 **Bug Reports**: [Open an issue](https://github.com/Metatable-ai/nomad_scale_to_zero/issues/new) with reproduction steps
- 💬 **Questions**: Use [GitHub Discussions](https://github.com/Metatable-ai/nomad_scale_to_zero/discussions) for questions
- 🔧 **Component Docs**: See [activity-store/README.md](activity-store/README.md) and [idle-scaler/README.md](idle-scaler/README.md)

### For Maintainers

- 🚀 **Creating Releases**: See [RELEASE.md](RELEASE.md) for the complete release process
- 📝 **Changelog**: See [CHANGELOG.md](CHANGELOG.md) for version history

## 🗺️ Roadmap

Future enhancements we're considering:

- [ ] Metrics and monitoring integration (Prometheus/Grafana)
- [ ] Support for multiple activity stores simultaneously
- [ ] Configurable wake-up strategies (parallel scaling, gradual rollout)
- [ ] Integration with other ingress controllers (nginx, envoy)
- [ ] Webhook notifications for scale events
- [ ] Advanced idle detection (request rate, resource usage)

Have ideas? [Open a feature request](https://github.com/Metatable-ai/nomad_scale_to_zero/issues/new) or start a [discussion](https://github.com/Metatable-ai/nomad_scale_to_zero/discussions)!

## 📄 License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

Built with:
- [HashiCorp Nomad](https://www.nomadproject.io/) - Workload orchestration
- [HashiCorp Consul](https://www.consul.io/) - Service discovery and KV storage
- [Traefik](https://traefik.io/) - Cloud-native ingress proxy

---

**Ready to get started?** Check out our [Quick Start](#-quick-start) guide or dive into [LOCAL_TESTING.md](LOCAL_TESTING.md) for detailed setup instructions.

**Want to contribute?** Read our [Contributing Guide](CONTRIBUTING.md) to get involved!
