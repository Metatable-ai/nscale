#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

set -eu

label="${1:-snapshot}"
redis_addr="${E2E_REDIS_ADDR:-redis:6379}"
redis_host="${redis_addr%:*}"
redis_port="${redis_addr#*:}"
redis_auth_args=""

if [ -n "${E2E_REDIS_PASSWORD:-}" ]; then
  redis_auth_args="-a ${E2E_REDIS_PASSWORD}"
fi

echo "=== Redis info ($label) ==="
# shellcheck disable=SC2086
redis-cli -h "$redis_host" -p "$redis_port" $redis_auth_args INFO memory cpu stats clients | grep -E '^(used_memory_human|used_memory_peak_human|used_cpu_sys|used_cpu_user|instantaneous_ops_per_sec|connected_clients|expired_keys):' || true