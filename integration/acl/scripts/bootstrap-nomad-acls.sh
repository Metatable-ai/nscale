#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Bootstrap Nomad ACLs (sidecar — runs once, then exits).
# Assumes Nomad is already running and healthy with ACLs enabled.
# Creates management token, nscale policy + scoped token.
# Writes tokens to /bootstrap/nomad.env.
#
# Uses `nomad` CLI + `wget` (available in hashicorp/nomad Alpine image).
# Does NOT depend on curl or jq.

set -eu

BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/bootstrap}"
NOMAD_ADDR="${NOMAD_ADDR:-http://nomad:4646}"
POLICY_DIR="/policies"

export NOMAD_ADDR

# ── Wait for Nomad leader ─────────────────────────────────
echo "Waiting for Nomad leader..."
elapsed=0
while true; do
  if [ "$elapsed" -ge 120 ]; then
    echo "ERROR: Nomad did not elect leader within 120s" >&2
    exit 1
  fi
  leader="$(wget -qO- "$NOMAD_ADDR/v1/status/leader" 2>/dev/null)" || leader=""
  if [ -n "$leader" ] && [ "$leader" != '""' ]; then
    echo "Nomad leader: $leader"
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

# In -dev mode, client runs in same process as server.
# Once leader is elected, the node is ready.
# /v1/nodes requires a token (403) before ACL bootstrap, so skip it.

# ── Bootstrap Nomad ACLs ─────────────────────────────────
echo "Bootstrapping Nomad ACLs..."
BOOTSTRAP_OUTPUT="$(nomad acl bootstrap -address="$NOMAD_ADDR" 2>&1)"
NOMAD_MGMT_TOKEN="$(echo "$BOOTSTRAP_OUTPUT" | awk '/Secret ID/{print $NF}')"

if [ -z "$NOMAD_MGMT_TOKEN" ]; then
  echo "ERROR: Failed to bootstrap Nomad ACLs" >&2
  echo "$BOOTSTRAP_OUTPUT" >&2
  exit 1
fi

export NOMAD_TOKEN="$NOMAD_MGMT_TOKEN"

# ── Create nscale policy + token ──────────────────────────
echo "Creating nscale Nomad policy..."
nomad acl policy apply \
  -address="$NOMAD_ADDR" \
  -description "nscale scale-to-zero" \
  nscale "$POLICY_DIR/nomad-nscale.hcl" >/dev/null

echo "Creating nscale Nomad token..."
TOKEN_OUTPUT="$(nomad acl token create \
  -address="$NOMAD_ADDR" \
  -name "nscale" \
  -policy nscale \
  -type client 2>&1)"
NOMAD_NSCALE_TOKEN="$(echo "$TOKEN_OUTPUT" | awk '/Secret ID/{print $NF}')"

if [ -z "$NOMAD_NSCALE_TOKEN" ]; then
  echo "ERROR: Failed to create nscale token" >&2
  echo "$TOKEN_OUTPUT" >&2
  exit 1
fi

# ── Write token env file ─────────────────────────────────
cat > "$BOOTSTRAP_DIR/nomad.env" <<EOF
NOMAD_MGMT_TOKEN=$NOMAD_MGMT_TOKEN
NOMAD_NSCALE_TOKEN=$NOMAD_NSCALE_TOKEN
EOF

echo "Nomad ACL bootstrap complete → $BOOTSTRAP_DIR/nomad.env"
