#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Start nscale after loading bootstrapped ACL tokens.

set -eu

BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/bootstrap}"

. /scripts/bootstrap-env.sh
load_bootstrap_env "$BOOTSTRAP_DIR/consul.env" 120
load_bootstrap_env "$BOOTSTRAP_DIR/nomad.env" 120

# Map tokens into nscale config env vars.
# Figment uses Env::prefixed("NSCALE_").split("__"), so double underscores
# become nesting separators: NSCALE_NOMAD__TOKEN → nomad.token
export NSCALE_NOMAD__TOKEN="$NOMAD_NSCALE_TOKEN"
export NSCALE_CONSUL__TOKEN="$CONSUL_NSCALE_TOKEN"

echo "Starting nscale with ACL tokens..."
exec /app/nscale
