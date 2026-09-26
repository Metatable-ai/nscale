# Documentation

This directory holds operator-facing documentation for configuring, running, and tuning `nscale`.

The goal of these documents is to explain how the system behaves, which settings matter most, and how the surrounding components — Traefik, Nomad, Consul, Redis, and Kubernetes — should be configured so `nscale` can reliably scale services to zero and wake them again on demand.

## Available guides

- [`migration-autoscaling.md`](./migration-autoscaling.md) — upgrade from 2.2.x, controlled cutover, storage/config compatibility, multi-group reconciliation, and rollback.

- [`autoscaling-release-readiness.md`](./autoscaling-release-readiness.md) — current validation evidence, remaining production gates, and rollout limitations.

- [`job-submission.md`](./job-submission.md) — how to submit Nomad HCL through `/admin/jobs`, what tags nscale injects, and how auto-registration works.
- [`performance-configuration.md`](./performance-configuration.md) — baseline configuration guidance for production-style and mixed-fleet deployments, with explanations of the most important settings and how they interact.
- [`durable-registry.md`](./durable-registry.md) — etcd-backed registration storage with Redis cache/read-through behavior and multi-replica recovery notes.

Implementation and review history is recorded in [the autoscaling release plan](./plans/2026-09-27-autoscaling-release-fixes.md).
