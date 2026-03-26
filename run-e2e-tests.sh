#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

set -eu

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
NOMAD_ADDR="${E2E_NOMAD_ADDR:-http://nomad:4646}"
CONSUL_ADDR="${E2E_CONSUL_ADDR:-http://consul:8500}"
TRAEFIK_URL="${E2E_TRAEFIK_BASE_URL:-http://traefik:80}"
STORE_TYPE="${E2E_STORE_TYPE:-redis}"
SOAK_CYCLES="${E2E_SOAK_CYCLES:-3}"
IDLE_TIMEOUT="${E2E_IDLE_TIMEOUT:-10s}"
IDLE_CHECK_INTERVAL="${E2E_IDLE_CHECK_INTERVAL:-3s}"
TRAFFIC_SCENARIO="${E2E_TRAFFIC_SCENARIO:-storm}"
JOB_COUNT="${E2E_JOB_COUNT:-10}"
K6_TARGET_MODE="${E2E_K6_TARGET_MODE:-random}"

idle_timeout_seconds() {
	value="$1"
	case "$value" in
		*ms)
			echo 1
			;;
		*s)
			echo "${value%s}"
			;;
		*m)
			echo $(( ${value%m} * 60 ))
			;;
		*h)
			echo $(( ${value%h} * 3600 ))
			;;
		*)
			echo "$value"
			;;
	esac
}

idle_wait_seconds="$(( $(idle_timeout_seconds "$IDLE_TIMEOUT") + $(idle_timeout_seconds "$IDLE_CHECK_INTERVAL") + 15 ))"

submit_job() {
	job_file="$1"
	nomad job run -detach -address="$NOMAD_ADDR" "$job_file"
}

printf "${CYAN}=== E2E configuration ===${NC}\n"
printf "  E2E_JOB_COUNT=%s\n" "$JOB_COUNT"
printf "  E2E_IDLE_TIMEOUT=%s\n" "$IDLE_TIMEOUT"
printf "  E2E_IDLE_CHECK_INTERVAL=%s\n" "$IDLE_CHECK_INTERVAL"
printf "  E2E_SOAK_CYCLES=%s\n" "$SOAK_CYCLES"
printf "  E2E_TRAFFIC_SCENARIO=%s\n" "$TRAFFIC_SCENARIO"
printf "  E2E_STORE_TYPE=%s\n" "$STORE_TYPE"

mkdir -p /tmp/e2e-generated

"$ROOT_DIR"/e2e/scripts/wait-for-http.sh "$CONSUL_ADDR/v1/status/leader" consul
"$ROOT_DIR"/e2e/scripts/wait-for-http.sh "$NOMAD_ADDR/v1/status/leader" nomad
"$ROOT_DIR"/e2e/scripts/wait-for-http.sh "$TRAEFIK_URL/ping" traefik

printf "${CYAN}=== Generate Nomad jobs ===${NC}\n"
"$ROOT_DIR"/e2e/scripts/render-workload-jobs.sh

printf "${CYAN}=== Submit workload jobs ===${NC}\n"
for job_file in /tmp/e2e-generated/jobs/*.nomad; do
	submit_job "$job_file"
done

"$ROOT_DIR"/e2e/scripts/wait-for-consul-services.sh "$JOB_COUNT"

primary_job="echo-s2z-0001"

printf "${CYAN}=== Initial Redis snapshot ===${NC}\n"
"$ROOT_DIR"/e2e/scripts/collect-redis-info.sh initial || true

printf "${CYAN}=== Wait for initial scale-to-zero ===${NC}\n"
"$ROOT_DIR"/e2e/scripts/wait-for-nomad-job.sh "$primary_job" 0 "$idle_wait_seconds"

cycle=1
while [ "$cycle" -le "$SOAK_CYCLES" ]; do
	printf "${CYAN}=== Soak cycle %s/%s ===${NC}\n" "$cycle" "$SOAK_CYCLES"
	service_number=$(( ((cycle - 1) % JOB_COUNT) + 1 ))
	selected_service_name="$(printf 'echo-s2z-%04d' "$service_number")"
	export E2E_K6_TARGET_MODE="$K6_TARGET_MODE"
	if [ "$K6_TARGET_MODE" = "fixed" ]; then
		export E2E_K6_SERVICE_NAME="$selected_service_name"
	else
		unset E2E_K6_SERVICE_NAME
	fi
	"$ROOT_DIR"/e2e/scripts/run-k6-scenario.sh &
	k6_pid=$!
	if [ "$K6_TARGET_MODE" = "fixed" ]; then
		"$ROOT_DIR"/e2e/scripts/wait-for-nomad-job.sh "$selected_service_name" 1 60
	else
		"$ROOT_DIR"/e2e/scripts/wait-for-nomad-running-count.sh "echo-s2z-" 1 at-least 60 "$JOB_COUNT"
	fi
	"$ROOT_DIR"/e2e/scripts/collect-redis-info.sh "cycle-${cycle}-post-wake" || true
	wait "$k6_pid"
	if [ "$K6_TARGET_MODE" = "fixed" ]; then
		"$ROOT_DIR"/e2e/scripts/wait-for-nomad-job.sh "$selected_service_name" 0 "$idle_wait_seconds"
	else
		"$ROOT_DIR"/e2e/scripts/wait-for-nomad-running-count.sh "echo-s2z-" 0 exact "$idle_wait_seconds" "$JOB_COUNT"
	fi
	cycle=$((cycle + 1))
done

printf "${CYAN}=== E2E bootstrap ===${NC}\n"
printf "Rendered jobs were submitted to Nomad, idle-scaler was started, and cold-start soak cycles were executed with k6.\n"
printf "This is still the first implementation slice, but now it performs a real wake -> healthy -> idle -> zero loop for at least one service.\n"

printf "${GREEN}E2E scaffold is ready${NC}\n"