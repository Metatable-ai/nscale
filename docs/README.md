# Documentation

This directory holds operator-facing documentation for configuring, running, and tuning `nscale`.

The goal of these documents is to explain how the system behaves, which settings matter most, and how the surrounding components — Traefik, Nomad, Consul, Redis, and Kubernetes — should be configured so `nscale` can reliably scale services to zero and wake them again on demand.

## Available guides

- [`job-submission.md`](./job-submission.md) — how to submit Nomad HCL through `/admin/jobs`, what tags nscale injects, and how auto-registration works.
- [`performance-configuration.md`](./performance-configuration.md) — baseline configuration guidance for production-style and mixed-fleet deployments, with explanations of the most important settings and how they interact.
- [`durable-registry.md`](./durable-registry.md) — etcd-backed registration storage with Redis cache/read-through behavior and multi-replica recovery notes.

Additional guides for deployment, troubleshooting, and observability are in progress.
