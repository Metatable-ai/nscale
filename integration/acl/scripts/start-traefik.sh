#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Start Traefik with ACL-bootstrapped config (contains catalog token).

set -eu

BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/bootstrap}"

. /scripts/bootstrap-env.sh
# Wait for the bootstrapped traefik.yml (written by bootstrap-consul-acls.sh)
wait_for_bootstrap_file "$BOOTSTRAP_DIR/traefik.yml" 120

echo "Starting Traefik with ACL-enabled config..."
exec traefik --configfile="$BOOTSTRAP_DIR/traefik.yml"
