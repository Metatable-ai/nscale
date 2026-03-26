#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

set -e

: "${E2E_JOB_COUNT:=10}"
: "${E2E_IDLE_TIMEOUT:=10s}"
: "${E2E_IDLE_CHECK_INTERVAL:=3s}"
: "${E2E_REQUEST_TIMEOUT:=45s}"
: "${E2E_SOAK_CYCLES:=3}"
: "${E2E_TRAFFIC_SCENARIO:=storm}"
: "${E2E_WARMUP_VUS:=5}"
: "${E2E_WARMUP_DURATION:=10s}"
: "${E2E_BURST_VUS:=50}"
: "${E2E_BURST_DURATION:=20s}"
: "${E2E_STORM_VUS:=100}"
: "${E2E_STORM_DURATION:=30s}"
: "${E2E_STORM_RATE:=250}"
: "${E2E_STORM_PREALLOCATED_VUS:=150}"

export E2E_JOB_COUNT
export E2E_IDLE_TIMEOUT
export E2E_IDLE_CHECK_INTERVAL
export E2E_REQUEST_TIMEOUT
export E2E_SOAK_CYCLES
export E2E_TRAFFIC_SCENARIO
export E2E_WARMUP_VUS
export E2E_WARMUP_DURATION
export E2E_BURST_VUS
export E2E_BURST_DURATION
export E2E_STORM_VUS
export E2E_STORM_DURATION
export E2E_STORM_RATE
export E2E_STORM_PREALLOCATED_VUS

COMPOSE_FILE="docker-compose.e2e.yml"

printf 'Running Docker e2e soak with:\n'
printf '  E2E_JOB_COUNT=%s\n' "$E2E_JOB_COUNT"
printf '  E2E_IDLE_TIMEOUT=%s\n' "$E2E_IDLE_TIMEOUT"
printf '  E2E_IDLE_CHECK_INTERVAL=%s\n' "$E2E_IDLE_CHECK_INTERVAL"
printf '  E2E_SOAK_CYCLES=%s\n' "$E2E_SOAK_CYCLES"
printf '  E2E_TRAFFIC_SCENARIO=%s\n' "$E2E_TRAFFIC_SCENARIO"
printf '  E2E_STORM_VUS=%s\n' "$E2E_STORM_VUS"
printf '  E2E_STORM_DURATION=%s\n' "$E2E_STORM_DURATION"
printf '  E2E_STORM_RATE=%s\n' "$E2E_STORM_RATE"

printf 'Cleaning previous Docker e2e stack state...\n'
docker compose -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true

exec docker compose -f "$COMPOSE_FILE" up --build --force-recreate --abort-on-container-exit --exit-code-from e2e-runner