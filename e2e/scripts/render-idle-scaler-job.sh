#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
output_file="/tmp/e2e-generated/idle-scaler.nomad"

export E2E_STORE_TYPE="${E2E_STORE_TYPE:-redis}"
export E2E_IDLE_CHECK_INTERVAL="${E2E_IDLE_CHECK_INTERVAL:-3s}"
export E2E_IDLE_TIMEOUT="${E2E_IDLE_TIMEOUT:-10s}"

mkdir -p /tmp/e2e-generated
envsubst < "$ROOT_DIR"/e2e/nomad/jobs/idle-scaler.nomad.tpl > "$output_file"

echo "Rendered idle-scaler job into ${output_file}"