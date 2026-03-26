#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

set -eu

job_prefix="$1"
expected_running="$2"
match_mode="${3:-exact}"
timeout_seconds="${4:-120}"
job_count="${5:-${E2E_JOB_COUNT:-10}}"
nomad_addr="${E2E_NOMAD_ADDR:-http://nomad:4646}"

start="$(date +%s)"
while true; do
  total_running=0

  i=1
  while [ "$i" -le "$job_count" ]; do
    job_name="$(printf '%s%04d' "$job_prefix" "$i")"
    job_allocations_json="$(curl -fsS "$nomad_addr/v1/job/$job_name/allocations" 2>/dev/null || true)"
    if [ -n "$job_allocations_json" ]; then
      running="$(printf '%s' "$job_allocations_json" | jq -r '[.[] | select(.ClientStatus == "running")] | length')"
    else
      running=0
    fi

    total_running=$((total_running + running))
    i=$((i + 1))
  done

  case "$match_mode" in
    at-least)
      if [ "$total_running" -ge "$expected_running" ]; then
        echo "Jobs ${job_prefix}* reached running=${total_running} (threshold >= ${expected_running})"
        exit 0
      fi
      ;;
    exact)
      if [ "$total_running" -eq "$expected_running" ]; then
        echo "Jobs ${job_prefix}* reached running=${total_running}"
        exit 0
      fi
      ;;
    *)
      echo "Unknown match mode: $match_mode" >&2
      exit 1
      ;;
  esac

  now="$(date +%s)"
  if [ $((now - start)) -ge "$timeout_seconds" ]; then
    echo "Timed out waiting for jobs ${job_prefix}* to reach running=${expected_running} (last running=${total_running}, mode=${match_mode})" >&2
    exit 1
  fi

  sleep 2
done