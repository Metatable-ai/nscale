#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Bootstrap Consul ACLs. Creates management token, nscale policy+token,
# Traefik catalog-read policy+token, and Nomad agent policy+token.
# Writes all tokens to /bootstrap/consul.env and a templated traefik.yml.

set -eu

BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/bootstrap}"
CONSUL_ADDR="${CONSUL_ADDR:-http://consul:8500}"
POLICY_DIR="/policies"
TRAEFIK_TEMPLATE="/templates/traefik.yml"

# ── Wait for Consul leader ───────────────────────────────
echo "Waiting for Consul leader..."
while true; do
  leader="$(curl -fsS "$CONSUL_ADDR/v1/status/leader" 2>/dev/null | tr -d '"')" || leader=""
  if [ -n "$leader" ] && [ "$leader" != "" ]; then
    echo "Consul leader: $leader"
    break
  fi
  sleep 1
done

mkdir -p "$BOOTSTRAP_DIR"

# ── Bootstrap ACL system ─────────────────────────────────
echo "Bootstrapping Consul ACLs..."
CONSUL_MGMT_TOKEN="$(curl -fsS -X PUT "$CONSUL_ADDR/v1/acl/bootstrap" | jq -r '.SecretID')"
export CONSUL_HTTP_TOKEN="$CONSUL_MGMT_TOKEN"

# ── nscale policy + token ────────────────────────────────
echo "Creating nscale Consul policy..."
POLICY_RULES="$(cat "$POLICY_DIR/consul-nscale.hcl")"
curl -fsS -X PUT "$CONSUL_ADDR/v1/acl/policy" \
  -H "X-Consul-Token: $CONSUL_MGMT_TOKEN" \
  -d "{\"Name\": \"nscale\", \"Rules\": $(echo "$POLICY_RULES" | jq -Rs .)}" > /dev/null

CONSUL_NSCALE_TOKEN="$(curl -fsS -X PUT "$CONSUL_ADDR/v1/acl/token" \
  -H "X-Consul-Token: $CONSUL_MGMT_TOKEN" \
  -d '{"Description": "nscale", "Policies": [{"Name": "nscale"}]}' | jq -r '.SecretID')"

# ── Traefik catalog-read policy + token ───────────────────
echo "Creating Traefik catalog-read policy..."
CATALOG_RULES="$(cat "$POLICY_DIR/consul-catalog-read.hcl")"
curl -fsS -X PUT "$CONSUL_ADDR/v1/acl/policy" \
  -H "X-Consul-Token: $CONSUL_MGMT_TOKEN" \
  -d "{\"Name\": \"catalog-read\", \"Rules\": $(echo "$CATALOG_RULES" | jq -Rs .)}" > /dev/null

CONSUL_CATALOG_TOKEN="$(curl -fsS -X PUT "$CONSUL_ADDR/v1/acl/token" \
  -H "X-Consul-Token: $CONSUL_MGMT_TOKEN" \
  -d '{"Description": "catalog-read", "Policies": [{"Name": "catalog-read"}]}' | jq -r '.SecretID')"

# ── Nomad agent policy + token ────────────────────────────
echo "Creating Nomad agent Consul policy..."
AGENT_RULES="$(cat "$POLICY_DIR/consul-nomad-agent.hcl")"
curl -fsS -X PUT "$CONSUL_ADDR/v1/acl/policy" \
  -H "X-Consul-Token: $CONSUL_MGMT_TOKEN" \
  -d "{\"Name\": \"nomad-agent\", \"Rules\": $(echo "$AGENT_RULES" | jq -Rs .)}" > /dev/null

CONSUL_NOMAD_AGENT_TOKEN="$(curl -fsS -X PUT "$CONSUL_ADDR/v1/acl/token" \
  -H "X-Consul-Token: $CONSUL_MGMT_TOKEN" \
  -d '{"Description": "nomad-agent", "Policies": [{"Name": "nomad-agent"}]}' | jq -r '.SecretID')"

# ── Set Consul agent default token ───────────────────────
echo "Setting Consul agent default token..."
curl -fsS -X PUT "$CONSUL_ADDR/v1/agent/token/default" \
  -H "X-Consul-Token: $CONSUL_MGMT_TOKEN" \
  -d "{\"Token\": \"$CONSUL_NOMAD_AGENT_TOKEN\"}" > /dev/null

# ── Template Traefik config with catalog token ────────────
if [ -f "$TRAEFIK_TEMPLATE" ]; then
  export CONSUL_CATALOG_TOKEN
  sed "s|\${CONSUL_CATALOG_TOKEN}|$CONSUL_CATALOG_TOKEN|g" \
    "$TRAEFIK_TEMPLATE" > "$BOOTSTRAP_DIR/traefik.yml"
  echo "Wrote $BOOTSTRAP_DIR/traefik.yml with catalog token"
fi

# ── Write token env file ─────────────────────────────────
cat > "$BOOTSTRAP_DIR/consul.env" <<EOF
CONSUL_MGMT_TOKEN=$CONSUL_MGMT_TOKEN
CONSUL_NSCALE_TOKEN=$CONSUL_NSCALE_TOKEN
CONSUL_CATALOG_TOKEN=$CONSUL_CATALOG_TOKEN
CONSUL_NOMAD_AGENT_TOKEN=$CONSUL_NOMAD_AGENT_TOKEN
EOF

echo "Consul ACL bootstrap complete → $BOOTSTRAP_DIR/consul.env"
