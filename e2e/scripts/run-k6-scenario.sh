#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
scenario="${E2E_TRAFFIC_SCENARIO:-storm}"
target_mode="${E2E_K6_TARGET_MODE:-random}"

case "$scenario" in
  warmup|storm|rolling)
    script_file="$ROOT_DIR/e2e/k6/${scenario}.js"
    ;;
  *)
    echo "Unknown E2E_TRAFFIC_SCENARIO: $scenario" >&2
    exit 1
    ;;
esac

if [ "$target_mode" = "fixed" ]; then
  echo "Running k6 scenario $scenario against ${E2E_K6_SERVICE_NAME:-echo-s2z-0001}"
else
  echo "Running k6 scenario $scenario with ${target_mode} job selection across ${E2E_JOB_COUNT:-10} jobs"
fi
k6 run "$script_file"