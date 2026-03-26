#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

set -eu

job_name="$1"
expected_running="$2"
timeout_seconds="${3:-120}"
nomad_addr="${E2E_NOMAD_ADDR:-http://nomad:4646}"

start="$(date +%s)"
while true; do
  job_allocations_json="$(curl -fsS "$nomad_addr/v1/job/$job_name/allocations" 2>/dev/null || true)"
  if [ -n "$job_allocations_json" ]; then
    running="$(printf '%s' "$job_allocations_json" | jq -r '[.[] | select(.ClientStatus == "running")] | length')"
  else
    running=0
  fi

  if [ "$running" = "$expected_running" ]; then
    echo "Job $job_name reached running=$running"
    exit 0
  fi

  now="$(date +%s)"
  if [ $((now - start)) -ge "$timeout_seconds" ]; then
    echo "Timed out waiting for $job_name to reach running=$expected_running (last running=$running)" >&2
    curl -fsS "$nomad_addr/v1/job/$job_name/allocations" || true
    exit 1
  fi

  sleep 2
done