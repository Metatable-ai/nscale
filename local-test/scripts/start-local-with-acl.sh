#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_TEST_DIR="$ROOT_DIR/local-test"

CONSUL_CONFIG="/tmp/consul.local.hcl"
NOMAD_CONFIG="/tmp/nomad.local.hcl"
TRAEFIK_CONFIG="/tmp/traefik.local.yaml"
S2Z_ENV_FILE="/tmp/s2z.env"

CONSUL_POLICY_FILE="/tmp/scale-to-zero-consul-policy.hcl"
CONSUL_CATALOG_POLICY_FILE="/tmp/consul-catalog-read-policy.hcl"
NOMAD_AGENT_CONSUL_POLICY_FILE="/tmp/nomad-agent-consul-policy.hcl"
NOMAD_POLICY_FILE="/tmp/scale-to-zero-policy.hcl"
IDLE_SCALER_JOB="/tmp/idle-scaler.with-tokens.hcl"

cleanup() {
  if [[ -n "${TRAEFIK_PID:-}" ]] && kill -0 "$TRAEFIK_PID" 2>/dev/null; then kill "$TRAEFIK_PID"; fi
  if [[ -n "${NOMAD_PID:-}" ]] && kill -0 "$NOMAD_PID" 2>/dev/null; then kill "$NOMAD_PID"; fi
  if [[ -n "${CONSUL_PID:-}" ]] && kill -0 "$CONSUL_PID" 2>/dev/null; then kill "$CONSUL_PID"; fi
}
trap cleanup EXIT

mkdir -p /tmp

cat > "$CONSUL_CONFIG" <<'EOF'
acl {
  enabled = true
  default_policy = "deny"
  enable_token_persistence = true
}

# Enable shorter anti-entropy sync interval for faster service updates
performance {
  leave_drain_time = "5s"
}
EOF

cat > "$NOMAD_CONFIG" <<'EOF'
data_dir  = "/tmp/nomad"
bind_addr = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
  options = {
    "driver.raw_exec.enable"     = "1"
    "driver.docker.enable"       = "1"
    "driver.raw_exec.no_cgroups" = "1"
  }
}

acl {
  enabled = true
}
EOF

cat > "$CONSUL_POLICY_FILE" <<'EOF'
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
EOF

cat > "$CONSUL_CATALOG_POLICY_FILE" <<'EOF'
node_prefix "" {
  policy = "read"
}

service_prefix "" {
  policy = "read"
}
EOF

# Policy for Nomad agent to register/deregister services in Consul
cat > "$NOMAD_AGENT_CONSUL_POLICY_FILE" <<'EOF'
agent_prefix "" {
  policy = "read"
}

node_prefix "" {
  policy = "write"
}

service_prefix "" {
  policy = "write"
}

# Required for checking service health
session_prefix "" {
  policy = "write"
}
EOF

cat > "$NOMAD_POLICY_FILE" <<'EOF'
namespace "*" {
  policy = "write"
  capabilities = ["submit-job", "read-job", "scale-job"]
}
EOF

if command -v docker >/dev/null 2>&1 && command -v docker-compose >/dev/null 2>&1; then
  (cd "$LOCAL_TEST_DIR" && docker-compose up -d)
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  (cd "$LOCAL_TEST_DIR" && docker compose up -d)
fi

consul agent -dev -client=0.0.0.0 -ui -config-file "$CONSUL_CONFIG" >/tmp/consul.log 2>&1 &
CONSUL_PID=$!

until curl -s http://localhost:8500/v1/status/leader >/dev/null; do sleep 0.5; done

CONSUL_MGMT_TOKEN=$(consul acl bootstrap -format=json | jq -r '.SecretID')
export CONSUL_HTTP_TOKEN="$CONSUL_MGMT_TOKEN"

consul acl policy create -name "scale-to-zero" -rules @"$CONSUL_POLICY_FILE" >/dev/null
CONSUL_S2Z_TOKEN=$(consul acl token create -description "scale-to-zero" -policy-name "scale-to-zero" -format=json | jq -r '.SecretID')

consul acl policy create -name "catalog-read" -rules @"$CONSUL_CATALOG_POLICY_FILE" >/dev/null
CONSUL_CATALOG_TOKEN=$(consul acl token create -description "catalog-read" -policy-name "catalog-read" -format=json | jq -r '.SecretID')

# Create policy for Nomad agent (service registration/deregistration)
consul acl policy create -name "nomad-agent" -rules @"$NOMAD_AGENT_CONSUL_POLICY_FILE" >/dev/null
CONSUL_NOMAD_AGENT_TOKEN=$(consul acl token create -description "nomad-agent" -policy-name "nomad-agent" -format=json | jq -r '.SecretID')

# CRITICAL: Set the Consul agent's default token for anti-entropy catalog sync
# This allows the agent to deregister services/checks from the catalog when they're removed locally
consul acl set-agent-token default "$CONSUL_NOMAD_AGENT_TOKEN"

cat > "$NOMAD_CONFIG" <<EOF
data_dir  = "/tmp/nomad"
bind_addr = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
  options = {
    "driver.raw_exec.enable"     = "1"
    "driver.docker.enable"       = "1"
    "driver.raw_exec.no_cgroups" = "1"
  }
}

acl {
  enabled = true
}

consul {
  address = "127.0.0.1:8500"
  token   = "$CONSUL_NOMAD_AGENT_TOKEN"
}
EOF

nomad agent -dev -bind=0.0.0.0 -network-interface=en0 -config "$NOMAD_CONFIG" >/tmp/nomad.log 2>&1 &
NOMAD_PID=$!

until curl -s http://localhost:4646/v1/status/leader >/dev/null; do sleep 0.5; done

NOMAD_MGMT_TOKEN=$(nomad acl bootstrap -json | jq -r '.SecretID')
export NOMAD_TOKEN="$NOMAD_MGMT_TOKEN"

nomad acl policy apply -description "scale-to-zero" scale-to-zero "$NOMAD_POLICY_FILE" >/dev/null
NOMAD_S2Z_TOKEN=$(nomad acl token create -name "scale-to-zero" -policy scale-to-zero -json | jq -r '.SecretID')

cat > "$S2Z_ENV_FILE" <<EOF
export S2Z_NOMAD_ADDR=http://127.0.0.1:4646
export S2Z_CONSUL_ADDR=http://127.0.0.1:8500
export S2Z_REDIS_ADDR=127.0.0.1:6379
export S2Z_ACTIVITY_STORE=redis
export S2Z_JOB_SPEC_STORE=redis
export S2Z_NOMAD_TOKEN=$NOMAD_S2Z_TOKEN
export S2Z_CONSUL_TOKEN=$CONSUL_S2Z_TOKEN
export NOMAD_TOKEN=$NOMAD_S2Z_TOKEN
export CONSUL_TOKEN=$CONSUL_S2Z_TOKEN
export CONSUL_HTTP_TOKEN=$CONSUL_CATALOG_TOKEN
EOF

source "$S2Z_ENV_FILE"

cat > "$TRAEFIK_CONFIG" <<EOF
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
    directory: "$LOCAL_TEST_DIR/traefik"
    watch: true
  consulCatalog:
    endpoint:
      address: "127.0.0.1:8500"
      scheme: "http"
      token: "${CONSUL_HTTP_TOKEN}"
    exposedByDefault: false
    watch: true
    refreshInterval: "5s"
    strictChecks:
      - "passing"
experimental:
  localPlugins:
    scalewaker:
      moduleName: "nomad_scale_to_zero/traefik-plugin"
      settings:
        useUnsafe: true
EOF

traefik --configfile="$TRAEFIK_CONFIG" --pluginslocal="$ROOT_DIR/plugins-local" >/tmp/traefik.log 2>&1 &
TRAEFIK_PID=$!

pushd "$ROOT_DIR/idle-scaler" >/dev/null
GO111MODULE=on go build -o /tmp/idle-scaler .
popd >/dev/null

cat > "$IDLE_SCALER_JOB" <<EOF
job "idle-scaler" {
  datacenters = ["dc1"]
  type        = "system"

  group "main" {
    task "idle-scaler" {
      driver = "raw_exec"

      config {
        command = "/tmp/idle-scaler"
      }

      env {
        NOMAD_ADDR            = "http://127.0.0.1:4646"
        CONSUL_ADDR           = "http://127.0.0.1:8500"
        NOMAD_TOKEN           = "$NOMAD_S2Z_TOKEN"
        CONSUL_TOKEN          = "$CONSUL_S2Z_TOKEN"
        IDLE_CHECK_INTERVAL   = "30s"
        DEFAULT_IDLE_TIMEOUT  = "60s"
        PURGE_ON_SCALEDOWN    = "false"

        # Redis running in Docker, exposed on host port 6379
        REDIS_ADDR            = "127.0.0.1:6379"
        REDIS_PASSWORD        = ""
        STORE_TYPE            = "redis"
      }

      resources {
        cpu    = 2
        memory = 32
      }
    }
  }
}
EOF

nomad job run "$IDLE_SCALER_JOB" >/dev/null

echo "=== Started local stack with ACLs ==="
echo "Consul UI:  http://localhost:8500"
echo "Nomad UI:   http://localhost:4646"
echo "Traefik UI: http://localhost:8080"
echo "Tokens exported in: $S2Z_ENV_FILE"
echo "Logs: /tmp/consul.log, /tmp/nomad.log, /tmp/traefik.log"

tail -f /tmp/traefik.log
