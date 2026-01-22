<!--
// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0
-->

# Local Testing Plan

## Prerequisites

- Nomad CLI (local agent)
- Consul (local agent)
- Traefik (local binary)
- Go 1.21+
- curl, jq
- (Optional) Redis (only if using Redis stores)

## Test Environment (Local Binaries)

We run Nomad, Consul, and Traefik as local processes to avoid Docker Desktop cgroup issues. The idle-scaler runs as a Nomad system job inside the cluster.

### 0) Export local environment variables (V2 config)

Set the infra endpoints for the Traefik plugin (required for local runs):

```bash
export S2Z_NOMAD_ADDR=http://localhost:4646
export S2Z_CONSUL_ADDR=http://localhost:8500
export S2Z_ACTIVITY_STORE=redis
export S2Z_JOB_SPEC_STORE=redis
export S2Z_REDIS_ADDR=127.0.0.1:6379
export S2Z_REDIS_PASSWORD=localtestpassword
export S2Z_NOMAD_TOKEN=
export S2Z_CONSUL_TOKEN=

# Traefik Consul Catalog (used by Traefik itself, not the plugin)
export CONSUL_HTTP_TOKEN=
```

### 0.1) ACL tokens (optional, but recommended if ACLs are enabled)

If you enable ACLs for Nomad and/or Consul, you must create and export tokens for both:

**Rules (recommended for local dev):**

- Use **separate tokens** for Nomad and Consul.
- Use **least-privilege policies** for app/runtime tokens.
- Keep **admin (god) tokens** only for bootstrapping and policy management.
- Prefer **environment variables** (not hard-coded in files).

#### Nomad ACLs

1. Enable ACLs in Nomad (local dev):

```hcl
# nomad.hcl (example)
acl {
  enabled = true
}
```

2. Create an **admin (management)** token:

```bash
nomad acl bootstrap
```

This outputs a **management token** (your god token). Save it securely.

3. Create a **scale-to-zero policy** (example):

```hcl
# scale-to-zero-policy.hcl
namespace "*" {
  policy = "write"
  capabilities = ["submit-job", "read-job", "scale-job"]
}
```

4. Create a **Nomad token** for scale-to-zero:

```bash
nomad acl policy apply scale-to-zero scale-to-zero-policy.hcl
nomad acl token create -name "scale-to-zero" -policy scale-to-zero
```

5. Export it for local runs:

```bash
export S2Z_NOMAD_TOKEN=...    # for Traefik plugin
export NOMAD_TOKEN=...        # for idle-scaler
```

#### Consul ACLs

1. Enable ACLs in Consul (local dev):

```hcl
# consul.hcl (example)
acl {
  enabled = true
  default_policy = "deny"
  enable_token_persistence = true
}
```

2. Create an **admin (management)** token:

```bash
consul acl bootstrap
```

This outputs a **management token** (your god token). Save it securely.

3. Create a **scale-to-zero policy** (example):

```hcl
# scale-to-zero-consul-policy.hcl
node_prefix "" {
  policy = "read"
}

key_prefix "scale-to-zero/" {
  policy = "write"
}

# Read for service discovery, write for potential cleanup of orphaned services
service_prefix "" {
  policy = "write"
}
```

4. Create a **Consul token** for scale-to-zero:

```bash
consul acl policy create -name "scale-to-zero" -rules @scale-to-zero-consul-policy.hcl
consul acl token create -description "scale-to-zero" -policy-name "scale-to-zero"
```

5. Export it for local runs:

```bash
export S2Z_CONSUL_TOKEN=...   # for Traefik plugin
export CONSUL_TOKEN=...       # for idle-scaler
```

> Tip: If you need to rotate tokens, update environment variables and restart Traefik/idle-scaler.

### 1) Start Consul (dev mode)

```bash
consul agent -dev -client=0.0.0.0 -ui
```

### 2) Start Nomad (dev mode)

```bash
nomad agent -dev -bind=0.0.0.0 -network-interface=en0
```

### 3) Start Traefik (local plugin)

Create a Traefik config file (once):

```bash
cat > /tmp/traefik.local.yaml <<'EOF'
api:
  insecure: true
  dashboard: true
log:
  level: DEBUG
entryPoints:
  http:
    address: ":80"
accessLog:
  filePath: /tmp/traefik-access.log
providers:
  file:
    directory: "/Users/hikionori/Documents/work/experiments/nomad_scale_to_zero/local-test/traefik"
    watch: true
  consulCatalog:
    endpoint:
      address: "127.0.0.1:8500"
      scheme: "http"
      token: "${CONSUL_HTTP_TOKEN}" # optional if Consul ACLs enabled
    exposedByDefault: false
experimental:
  localPlugins:
    scalewaker:
      moduleName: "nomad_scale_to_zero/traefik-plugin"
      settings:
        useUnsafe: true
EOF
```

Run Traefik:

```bash
traefik --configfile=/tmp/traefik.local.yaml --pluginslocal=./nomad_scale_to_zero/plugins-local```

## Testing Phases

### Phase 1: Basic Infrastructure

1. Verify Nomad is running:
   ```bash
   curl http://localhost:4646/v1/status/leader
   ```

2. Verify Consul is running:
   ```bash
   curl http://localhost:8500/v1/status/leader
   ```

3. Check Traefik dashboard:
   ```bash
   open http://localhost:8080
   ```

### Phase 2: Test Manual Scaling

1. Deploy a sample job with count=1:
   ```bash
   nomad job run local-test/sample-jobs/echo-server.hcl
   ```

2. Verify service registered in Consul:
   ```bash
   curl http://localhost:8500/v1/catalog/service/echo-server
   ```

3. Test traffic via Traefik:
   ```bash
   curl -H "Host: echo.localhost" http://localhost/
   ```

4. Scale to zero manually:
   ```bash
   nomad job scale echo-server main 0
   ```

5. Verify service is gone from Consul:
   ```bash
   curl http://localhost:8500/v1/catalog/service/echo-server
   # Should return []
   ```

6. Scale back up:
   ```bash
   nomad job scale echo-server main 1
   ```

### Phase 3: Test Idle-Scaler (Nomad System Job)

1. Build the idle-scaler binary:
   ```bash
   cd idle-scaler
   go build -o /tmp/idle-scaler .
   ```

2. Update the idle-scaler job to point at local Nomad/Consul:
  ```hcl
  # local-test/system-jobs/idle-scaler.hcl
  env {
    NOMAD_ADDR  = "http://localhost:4646"
    CONSUL_ADDR = "http://localhost:8500"
    # Optional (ACLs):
    # NOMAD_TOKEN  = "..."
    # CONSUL_TOKEN = "..."
  }
  ```

3. Run the idle-scaler as a Nomad system job (ensure /tmp/idle-scaler exists on the Nomad client):
   ```bash
   nomad job run local-test/system-jobs/idle-scaler.hcl
   ```

4. Deploy a job with scale-to-zero metadata:
   ```bash
   nomad job run local-test/sample-jobs/echo-s2z.hcl
   ```

5. Make a request to keep it alive:
   ```bash
   curl -H "Host: echo-s2z.localhost" http://localhost/
   ```

6. Wait for idle timeout (60s+) and verify scale-down:
   ```bash
   watch 'nomad job status echo-s2z | grep -A5 "Allocations"'
   ```

### Phase 4: Test Scale-Waker (Full Flow)

1. Traefik should already be running locally with the scalewaker plugin.

2. Deploy job at count=0:
   ```bash
   nomad job run local-test/sample-jobs/echo-s2z.hcl
   nomad job scale echo-s2z main 0
   ```

3. Verify job is running but no allocations:
   ```bash
   nomad job status echo-s2z
   # Should show count=0
   ```

4. Make request (should trigger wake-up):
   ```bash
   time curl -H "Host: echo-s2z.localhost" http://localhost/
   ```

6. Expected behavior:
   - Request waits ~5-10s (cold start)
   - Service starts, becomes healthy
   - Response is returned
   - Subsequent requests are fast

6. Wait for idle timeout and verify scale-down.

## Sample Job Files

### `sample-jobs/echo-server.hcl`

```hcl
job "echo-server" {
  group "main" {
    count = 1

    network {
      mode = "host"
      port "http" {}
    }

    task "echo" {
      driver = "docker"
      config {
        image = "hashicorp/http-echo"
        args  = ["-listen=:${NOMAD_PORT_http}", "-text=Hello from echo-server"]
        ports = ["http"]
      }
      resources {
        cpu    = 2
        memory = 16
      }

      service {
        provider     = "consul"
        port         = "http"
        address_mode = "host"
        tags = [
          "traefik.enable=true",
          "traefik.http.routers.echo.rule=Host(`echo.localhost`)",
          "traefik.http.routers.echo.entryPoints=http",
        ]
        check {
          type     = "http"
          path     = "/"
          interval = "1s"
          timeout  = "1s"
        }
      }
    }
  }
}
```

### `sample-jobs/echo-s2z.hcl`

```hcl
job "echo-s2z" {
  meta = {
    "scale-to-zero.enabled"      = "true"
    "scale-to-zero.idle-timeout" = "60"
    "scale-to-zero.job-spec-kv"  = "scale-to-zero/jobs/echo-s2z"
  }

  group "main" {
    count = 1

    network {
      mode = "host"
      port "http" {}
    }

    task "echo" {
      driver = "docker"
      config {
        image = "hashicorp/http-echo"
        args  = ["-listen=:${NOMAD_PORT_http}", "-text=Hello from scale-to-zero service"]
        ports = ["http"]
      }
      resources {
        cpu    = 2
        memory = 16
      }

      service {
        provider     = "consul"
        port         = "http"
        address_mode = "host"
        tags = [
          "traefik.enable=true",
          "traefik.http.routers.echo-s2z.rule=Host(`echo-s2z.localhost`)",
          "traefik.http.routers.echo-s2z.entryPoints=http",
          "traefik.http.middlewares.scalewaker-echo.plugin.scalewaker.serviceName=echo-s2z",
          "traefik.http.middlewares.scalewaker-echo.plugin.scalewaker.timeout=30s",
          "traefik.http.routers.echo-s2z.middlewares=scalewaker-echo",
        ]
        check {
          type     = "http"
          path     = "/"
          interval = "1s"
          timeout  = "1s"
        }
      }
    }
  }
}
```

### `sample-jobs/echo-s2z-vars.hcl`

This variant uses HCL2 variables for configuration. You can run it with a var file:

```bash
nomad job run \
  -var-file=local-test/sample-jobs/echo-s2z-vars.vars.hcl \
  local-test/sample-jobs/echo-s2z-vars.hcl
```

```hcl
variable "service_name" {
  type    = string
  default = "echo-s2z-vars"
}

variable "host" {
  type    = string
  default = "echo-s2z-vars.localhost"
}

variable "image" {
  type    = string
  default = "hashicorp/http-echo"
}

variable "response_text" {
  type    = string
  default = "Hello from scale-to-zero service (vars)!"
}

variable "idle_timeout" {
  type    = string
  default = "20"
}

variable "job_spec_kv" {
  type    = string
  default = "scale-to-zero/jobs/echo-s2z-vars"
}

job "echo-s2z-vars" {
  datacenters = ["dc1"]
  type        = "service"

  meta = {
    "scale-to-zero.enabled"      = "true"
    "scale-to-zero.idle-timeout" = var.idle_timeout
    "scale-to-zero.job-spec-kv"  = var.job_spec_kv
  }

  group "main" {
    count = 1

    network {
      mode = "host"
      port "http" {}
    }

    task "echo" {
      driver = "docker"
      config {
        image = var.image
        args  = ["-listen=:${NOMAD_PORT_http}", "-text=${var.response_text}"]
        ports = ["http"]
      }
      resources {
        cpu    = 2
        memory = 16
      }

      service {
        name         = var.service_name
        provider     = "consul"
        port         = "http"
        address_mode = "host"
        tags = [
          "traefik.enable=true",
          "traefik.http.routers.echo-s2z-vars.rule=Host(`${var.host}`)",
          "traefik.http.routers.echo-s2z-vars.entryPoints=http",
          "traefik.http.middlewares.scalewaker-echo-s2z-vars.plugin.scalewaker.serviceName=${var.service_name}",
          "traefik.http.middlewares.scalewaker-echo-s2z-vars.plugin.scalewaker.timeout=30s",
          "traefik.http.routers.echo-s2z-vars.middlewares=scalewaker-echo-s2z-vars",
        ]
        check {
          type     = "http"
          path     = "/"
          interval = "1s"
          timeout  = "1s"
        }
      }
    }
  }
}
```

## Manual Smoke Tests

The local-test helper scripts were removed to keep the repo minimal and easier to maintain. These commands cover the same checks.

### Wake-up (scale from 0 on request)

1. Scale a job down:

  - `nomad job scale echo-s2z main 0`

2. Send a request through Traefik (should trigger wake-up via the middleware):

  - `curl -H 'Host: echo-s2z.localhost' http://localhost/`

3. Verify allocations are running again:

  - `nomad job status echo-s2z`

### Idle scale-down (idle-scaler)

1. Ensure the job is running:

  - `nomad job scale echo-s2z main 1`

2. Wait for the configured idle timeout and confirm the group count becomes 0:

  - `nomad job status echo-s2z`

## Debugging Commands

```bash
# Check Nomad job status
nomad job status <job-name>

# View Nomad allocations
nomad alloc status <alloc-id>

# Check Consul service health
curl http://localhost:8500/v1/health/service/<service-name>?passing=true

# View Traefik configuration
curl http://localhost:8080/api/http/routers
curl http://localhost:8080/api/http/services

# Check Traefik access logs
tail -f /tmp/traefik-access.log

# View idle-scaler activity store (Consul KV)
curl http://localhost:8500/v1/kv/scale-to-zero/activity/?recurse=true | jq

# Manual Nomad scale command
nomad job scale <job-name> <group-name> <count>
```

## Success Criteria

- [ ] Infrastructure starts successfully
- [ ] Jobs can be deployed and accessed via Traefik
- [ ] Manual scaling (0→1, 1→0) works
- [ ] Idle-scaler correctly scales down after timeout
- [ ] Scale-waker correctly scales up on request
- [ ] Cold-start latency is acceptable (<10s)
- [ ] Metrics are being collected
- [ ] No request drops during scale-up
