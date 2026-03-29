#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Start Nomad with ACL tokens from the Consul bootstrap.
# Waits for consul.env, templates the Nomad config with the agent token,
# then starts Nomad in dev mode with ACLs enabled.

set -eu

BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/bootstrap}"
NOMAD_CONFIG_TEMPLATE="/templates/nomad.hcl"

# ── Source Consul tokens ──────────────────────────────────
. /scripts/bootstrap-env.sh
load_bootstrap_env "$BOOTSTRAP_DIR/consul.env" 120

# ── Template Nomad config with Consul agent token ─────────
echo "Writing Nomad config with Consul agent token..."
sed "s|\${CONSUL_NOMAD_AGENT_TOKEN}|$CONSUL_NOMAD_AGENT_TOKEN|g" \
  "$NOMAD_CONFIG_TEMPLATE" > /tmp/nomad-acl.hcl

# ── Start Nomad ──────────────────────────────────────────
echo "Starting Nomad agent with ACLs enabled..."
exec nomad agent -dev \
  -bind=0.0.0.0 \
  -network-interface=eth0 \
  -config=/tmp/nomad-acl.hcl
