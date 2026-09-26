# nscale Helm chart

This chart deploys `nscale` on Kubernetes and supports two operating modes:

- **External dependency mode** — `nscale` runs in-cluster while Nomad, Consul, Redis, and optionally etcd are provided externally.
- **Bundled dependency mode** — the chart deploys `nscale` and can also bundle Redis plus etcd for durable-registry mode.

The chart intentionally **does not** manage Traefik resources. `nscale` depends on external Traefik configuration so that both warm and cold traffic route through the proxy.

## Prerequisites

- A Kubernetes cluster with network reachability to Nomad and Consul
- Traefik configured separately to route managed services through `nscale`
- Redis available either externally or via `redis.enabled=true`
- Optional: etcd available externally or via `etcd.enabled=true` when `registry.durable.enabled=true`

## Install

### Minimal install with bundled Redis

```bash
helm install nscale ./charts/nscale \
  --namespace nscale \
  --create-namespace \
  --set redis.enabled=true \
  --set externalServices.nomad.addr=http://nomad.default.svc.cluster.local:4646 \
  --set externalServices.consul.addr=http://consul.default.svc.cluster.local:8500
```

### Install with external Redis

```bash
helm install nscale ./charts/nscale \
  --namespace nscale \
  --create-namespace \
  --set redis.externalUrl=redis://redis.default.svc.cluster.local:6379 \
  --set externalServices.nomad.addr=http://nomad.default.svc.cluster.local:4646 \
  --set externalServices.consul.addr=http://consul.default.svc.cluster.local:8500
```

### Enable durable registry mode

```bash
helm install nscale ./charts/nscale \
  --namespace nscale \
  --create-namespace \
  --set redis.enabled=true \
  --set registry.durable.enabled=true \
  --set etcd.enabled=true \
  --set externalServices.nomad.addr=http://nomad.default.svc.cluster.local:4646 \
  --set externalServices.consul.addr=http://consul.default.svc.cluster.local:8500
```

If you already have an external etcd cluster, leave `etcd.enabled=false` and provide `etcd.externalEndpoints` instead.

## Upgrade

For the autoscaling update from 2.2.x, use the [migration runbook](../../docs/migration-autoscaling.md).
The app deployment now uses `Recreate`. For this major upgrade, externally drain,
stop all old app pods, apply the reviewed values with `replicaCount=0`, then start only the new image.

Pin `image.tag`; an empty tag uses `Chart.appVersion`, now `3.0.0`. Verify the release artifact
is available before deployment. `Recreate` prevents overlapping versions in this Deployment;
it does not drain requests or stop proxies in other Deployments. Keep the explicit maintenance cutover.

The bundled Redis now defaults to `noeviction`, with a 100 MB data budget and a 256 MiB container
limit for headroom. Monitor memory and rejected writes. Existing custom `redis.config` values are
not rewritten: replace inherited `allkeys-lru` settings. Changing this config restarts Redis, so
back up registrations first. Persistence remains disabled by default with `dir /tmp`; enabling
the PVC at `/data` alone does not make that config persistent.

### Autoscaling release settings

```yaml
image:
  tag: "3.0.0"
config:
  proxy:
    endpointRefreshSecs: 2
  admin:
    existingSecret: nscale-admin
    secretKey: token
  scaling:
    autoDeregister:
      enabled: true
      notFoundThreshold: 5
externalServices:
  prometheus:
    url: http://prometheus.monitoring.svc.cluster.local:9090
    timeoutSecs: 5
```

Prometheus is omitted when its URL is empty. Admin authentication is unset unless the existing
Secret is configured (or supplied via `extraEnv`). The Secret is separate from Nomad/Consul ACL
credentials, and the chart does not create or embed its token. Health and metrics endpoints remain
public. Avoid duplicate admin-token environment variables when moving from `extraEnv` to these values.
Autoscaling policies themselves remain per-job registration payloads, not Helm values.

## Uninstall

```bash
helm uninstall nscale --namespace nscale
```

## Secret-backed ACL tokens

The chart supports both an existing Secret and chart-managed secret values.

### Reuse an existing Secret

```bash
helm install nscale ./charts/nscale \
  --namespace nscale \
  --create-namespace \
  --set redis.enabled=true \
  --set secrets.existingSecret=nscale-secrets
```

The Secret is expected to contain the default keys:

- `nomad_token`
- `consul_token`

You can override those key names with `secrets.secretKeys.nomadToken` and `secrets.secretKeys.consulToken`.

### Let the chart create the Secret

```bash
helm install nscale ./charts/nscale \
  --namespace nscale \
  --create-namespace \
  --set redis.enabled=true \
  --set secrets.create=true \
  --set secrets.nomadToken=REDACTED \
  --set secrets.consulToken=REDACTED
```

For production, reusing an externally managed Secret is the safer pattern.

## Important values

| Value | Purpose | Default |
|-------|---------|---------|
| `replicaCount` | Number of `nscale` pods | `1` |
| `image.tag` | Image tag; empty uses chart appVersion | `3.0.0` via appVersion |
| `config.proxy.endpointRefreshSecs` | Service endpoint pool refresh interval | `2` |
| `config.admin.existingSecret` | Existing Secret containing the admin bearer token | `""` |
| `config.admin.secretKey` | Key in the admin Secret | `token` |
| `config.scaling.autoDeregister.enabled` | Enable missing-job cleanup | `true` |
| `config.scaling.autoDeregister.notFoundThreshold` | Missing-job observations before cleanup | `5` |
| `externalServices.prometheus.url` | Aggregate metrics query URL | `""` |
| `externalServices.prometheus.timeoutSecs` | Prometheus query timeout | `5` |
| `image.repository` | nscale image repository | `ghcr.io/metatable-ai/nscale` |
| `externalServices.nomad.addr` | Nomad HTTP API base URL | `http://nomad.default.svc.cluster.local:4646` |
| `externalServices.consul.addr` | Consul HTTP API base URL | `http://consul.default.svc.cluster.local:8500` |
| `redis.enabled` | Deploy bundled Redis | `false` |
| `redis.externalUrl` | External Redis URL when bundled Redis is disabled | `redis://redis.default.svc.cluster.local:6379` |
| `registry.durable.enabled` | Enable durable registry mode in `nscale` | `false` |
| `etcd.enabled` | Deploy bundled etcd | `false` |
| `etcd.externalEndpoints` | External etcd endpoints when bundled etcd is disabled | `""` |
| `externalServices.traefik.metricsUrl` | Traefik Prometheus endpoint for traffic-aware scale-down | `""` |
| `service.proxy.type` | Service type for proxy traffic | `ClusterIP` |
| `service.admin.type` | Service type for admin endpoints | `ClusterIP` |
| `config.logging.format` | `NSCALE_LOG_FORMAT` value | `compact` |

See [`values.yaml`](./values.yaml) for the full set of options.

## Traefik integration notes

This chart only deploys `nscale` and its optional backing services. It does **not** create:

- Traefik fallback routers
- Traefik TLS configuration
- Consul Catalog provider configuration
- Nomad job router tags

Your Traefik configuration must still route both cold-path and warm-path traffic through the `nscale` proxy service created by this chart. In Nomad job tags, keep using `traefik.http.routers.<name>.service=s2z-nscale@file` (or your equivalent file-provider service target).
