# Autoscaling release readiness

Status as of 2026-09-27, for the `feat/autoscaling` working tree targeting **3.0.0**.

**Ready for a staging candidate; production sign-off is pending.** Previously confirmed release
blockers have fixes and regression coverage. The latest scoped status check found no additional
confirmed code blocker; it was not a new exhaustive audit of every branch path. The latest fixes
are still uncommitted, so the tested working tree must be captured in the release candidate.

## Validation evidence

| Validation | Result | Scope |
|---|---|---|
| Formatting, workspace check, strict Clippy | Passed | Latest implementation |
| `cargo nextest run --workspace --run-ignored all --test-threads 4` | 167 passed, none skipped | Latest implementation; disposable Redis and etcd, local mock HTTP servers |
| `integration/test-durable.sh` | Passed | Latest Rust behavior, before version/Helm packaging changes; real Nomad/Consul/Traefik/Redis/etcd, renamed-service removal and warm/cold cache recovery |
| `integration/test-autoscaling-regressions.sh` | Passed earlier | Before the final registration-replacement and failed-wake fixes |
| `integration/test-autoscaling-prometheus.sh` | Passed earlier | Before those final fixes; 759 successful load requests and metrics from two proxies |
| `integration/test-multigroup.sh` | Passed earlier | Before those final fixes; independent group wake and idle reduction |
| `integration/test-acl.sh` | Passed earlier | Before those final fixes; 23 assertions |
| Helm lint and semantic render checks | Passed | 3.0.0 default, configured, and zero-replica durable variants; no live Kubernetes upgrade |
| Staging rollout/rollback and prolonged soak | Not performed | No production-readiness claim from local tests |

The implementation history and earlier test counts are in the
[release-fixes plan](./plans/2026-09-27-autoscaling-release-fixes.md). Test containers and networks
were removed after validation. No release artifact was published or production deployment performed.

## Remaining production gates

These gates cover final validation and deployment configuration. The 3.0.0 chart now defaults to
`Recreate` and non-evicting Redis. Existing installations still need the coordinated migration
below, including review of inherited/custom Redis values. Migration examples, zero/two-replica
Helm renders, and chart lint pass locally; the actual old-to-new cutover and rollback remain
untested in staging.

1. Capture the final fixes in a candidate commit, then build an immutable candidate image/binary.
   The tag-triggered release workflow has not been exercised for this candidate.
2. Rerun the four earlier integration suites above on that exact candidate. Run the durable suite
   and workspace checks again if code changes after the recorded pass. Keep ACL and multi-proxy
   coverage in the release evidence.
3. In the intended staging topology, exercise cold wake, sustained load, idle reduction, service
   replacement, and long HTTP/WebSocket requests. Check actual counts, errors, latency, and that
   required metrics cover all proxies and services. Include a sustained run representative of the
   intended workload; no prolonged soak has been completed so far.
4. Follow the [migration guide](./migration-autoscaling.md): replace inherited/custom Redis
   `allkeys-lru` settings with `noeviction` and adequate memory headroom, pin the target image,
   and reconcile legacy multi-group registrations. The chart and Cargo packages target `3.0.0`;
   `Recreate` does not replace the documented external drain and stop-all cutover.
5. Rehearse coordinated proxy replacement and rollback. Verify graceful shutdown, Nomad drain/kill
   timing, shared Redis connectivity, and recovery from a `207` submission before production rollout.

Passing these gates supports a production decision. Requirements such as zero request loss during
network partitions or arbitrary allocation termination exceed the guarantees below.

## Behavior and operational limits

- Autoscaling controls running groups between `min_count` and `max_count`. Requests wake zero
  counts to the enabled policy’s minimum. Idle scale-to-zero remains a separate decision and can
  be disabled with `scale_to_zero = false`.
- Services in a group share count coordination and a policy; readiness and endpoint ports remain
  service-specific. Keep manually registered sibling policies consistent. `/admin/jobs` replaces
  the entire managed set, including removing omitted services and previous policies.
- Missing required metrics prevent reductions. Native latency/error samples may increase capacity
  but cannot authorize reductions. Configure complete aggregate observations for latency/error
  downsizing; Prometheus failure is not treated as zero load.
- Every proxy must share Redis. Request tokens refresh at most every five seconds and expire after
  thirty seconds without renewal. HTTP bodies and WebSocket tunnels remain tracked through closure.
  Redis admission errors return `503`; unreadable shared state blocks reductions and unforced purge.
- Drain and replace older proxies together. Mixed versions do not all participate in shared request
  tracking and mutation coordination. Graceful shutdown remains necessary; newly arriving requests,
  partitions, and direct/manual termination are not guaranteed lossless.
- A wake deadline includes queue time for that wake attempt. It is not a deadline for the complete
  HTTP lifecycle, backend retries, or an upgraded WebSocket tunnel.
- Nomad, etcd, and Redis do not share one transaction. `201` confirms registration replacement, not
  allocation health. `409` requires a later retry. `207` requires restoring the failed store and
  resubmitting the desired job/policy. Startup hydration is not stale-cache reconciliation.

See [job submission](./job-submission.md), [durable storage](./durable-registry.md), and
[performance configuration](./performance-configuration.md) for operator procedures.
