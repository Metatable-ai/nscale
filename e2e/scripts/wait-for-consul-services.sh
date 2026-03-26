#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

set -eu

expected_count="$1"
consul_addr="${E2E_CONSUL_ADDR:-http://consul:8500}"
timeout_seconds="${2:-120}"

start="$(date +%s)"
while true; do
  count="$(curl -fsS "$consul_addr/v1/agent/services" | jq '[to_entries[] | select(.value.Service | startswith("echo-s2z-"))] | length')"
  if [ "$count" -ge "$expected_count" ]; then
    echo "Consul has $count echo-s2z services registered"
    exit 0
  fi

  now="$(date +%s)"
  if [ $((now - start)) -ge "$timeout_seconds" ]; then
    echo "Timed out waiting for $expected_count echo-s2z services in Consul (last count=$count)" >&2
    exit 1
  fi

  sleep 2
done