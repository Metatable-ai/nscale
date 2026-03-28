#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

set -eu

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/e2e/scripts/load-profile.sh"
load_e2e_profile "${E2E_PROFILE:-certification}"

NOMAD_ADDR="${E2E_NOMAD_ADDR:-http://nomad-server:4646}"
CONSUL_ADDR="${E2E_CONSUL_ADDR:-http://consul:8500}"
TRAEFIK_URL="${E2E_TRAEFIK_BASE_URL:-http://traefik:80}"
STORE_TYPE="${E2E_STORE_TYPE:-redis}"
SOAK_CYCLES="${E2E_SOAK_CYCLES:-3}"
IDLE_TIMEOUT="${E2E_IDLE_TIMEOUT:-10s}"
IDLE_CHECK_INTERVAL="${E2E_IDLE_CHECK_INTERVAL:-3s}"
MIN_SCALE_DOWN_AGE="${E2E_MIN_SCALE_DOWN_AGE:-1m}"
TRAFFIC_SCENARIO="${E2E_TRAFFIC_SCENARIO:-storm}"
TRAFFIC_SHAPE_LIST="${E2E_TRAFFIC_SHAPE:-$TRAFFIC_SCENARIO}"
JOB_COUNT="${E2E_JOB_COUNT:-10}"
K6_TARGET_MODE="${E2E_K6_TARGET_MODE:-random}"
TARGET_NOMAD_CLIENTS="${E2E_TARGET_NOMAD_CLIENTS:-${E2E_NOMAD_CLIENTS:-1}}"
IDLE_SCALER_PLACEMENT="${E2E_TARGET_IDLE_SCALER_PLACEMENT:-docker-compose-service}"
IDLE_SCALER_ISOLATION_MODE="${E2E_TARGET_IDLE_SCALER_ISOLATION_MODE:-disabled}"
IDLE_SCALER_EXPECTED_RUNNING=1
REQUEST_TIMEOUT="${E2E_REQUEST_TIMEOUT:-45s}"
REQUESTED_SCENARIO_SET="${E2E_SCENARIO_SET:-mixed-traffic}"
SCENARIO_SET="$REQUESTED_SCENARIO_SET"
GENERATED_DIR="${E2E_GENERATED_DIR:-$ROOT_DIR/.e2e-generated}"
GENERATED_JOBS_DIR="${E2E_GENERATED_JOBS_DIR:-$GENERATED_DIR/jobs}"
WORKLOAD_MANIFEST_FILE="${E2E_WORKLOAD_MANIFEST_FILE:-$GENERATED_DIR/workload-manifest.tsv}"
WORKLOAD_PREFIX="echo-s2z-"

export E2E_GENERATED_DIR="$GENERATED_DIR"
export E2E_GENERATED_JOBS_DIR="$GENERATED_JOBS_DIR"
export E2E_WORKLOAD_MANIFEST_FILE="$WORKLOAD_MANIFEST_FILE"

timestamp_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
}

timestamp_millis() {
	value="$(date +%s%3N 2>/dev/null || true)"
	case "$value" in
		""|*N*)
			printf '%s000' "$(date +%s)"
			;;
		*)
			printf '%s' "$value"
			;;
	esac
}

slugify() {
	value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')"
	value="${value#-}"
	value="${value%-}"
	if [ -z "$value" ]; then
		value="artifact"
	fi
	printf '%s' "$value"
}

RUN_ID="${E2E_RUN_ID:-e2e-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
ARTIFACTS_DIR="${E2E_ARTIFACTS_DIR:-$ROOT_DIR/.e2e-artifacts/$RUN_ID}"
case "$ARTIFACTS_DIR" in
	/*)
		;;
	*)
		ARTIFACTS_DIR="$ROOT_DIR/$ARTIFACTS_DIR"
		;;
esac
K6_ARTIFACTS_DIR="${E2E_K6_ARTIFACTS_DIR:-$ARTIFACTS_DIR/k6}"
STATE_ARTIFACTS_DIR="${E2E_STATE_ARTIFACTS_DIR:-$ARTIFACTS_DIR/state}"
SCENARIO_ARTIFACTS_DIR="${E2E_SCENARIO_ARTIFACTS_DIR:-$ARTIFACTS_DIR/scenarios}"
WORKLOAD_ARTIFACTS_DIR="${E2E_WORKLOAD_ARTIFACTS_DIR:-$ARTIFACTS_DIR/workloads}"
CLEANUP_ARTIFACTS_DIR="${E2E_CLEANUP_ARTIFACTS_DIR:-$ARTIFACTS_DIR/cleanup}"
FAILURE_ARTIFACTS_DIR="${E2E_FAILURE_ARTIFACTS_DIR:-$ARTIFACTS_DIR/failures}"
EVENTS_FILE="$ARTIFACTS_DIR/events.jsonl"
RUN_METADATA_FILE="$ARTIFACTS_DIR/run-metadata.json"
RUN_STATUS_FILE="$ARTIFACTS_DIR/run-status.json"
RELEASE_GATES_FILE="${E2E_RELEASE_GATES_FILE:-$ARTIFACTS_DIR/release-gates.json}"
RELEASE_GATES_SUMMARY_FILE="${E2E_RELEASE_GATES_SUMMARY_FILE:-$ARTIFACTS_DIR/release-gates-summary.txt}"
CONSUL_BASELINE_FILE="$ARTIFACTS_DIR/consul-baseline.json"
RUN_STARTED_AT="$(timestamp_utc)"
RUN_STARTED_AT_MS="$(timestamp_millis)"
ACTIVE_SCENARIO=""
ARTIFACTS_READY=0
CONSUL_CLEANUP_LAST_DURATION_MS=0
CONSUL_WORKLOAD_CLEANUP_LAST_DURATION_MS=0
LAST_WORKLOAD_WAKE_DURATION_MS=0
LAST_WAKE_ALL_DURATION_MS=0
LAST_K6_WAKE_DURATION_MS=0
LAST_K6_LABEL=""
SCENARIO_RESULT_CONTEXT_JSON='{}'
LAST_SCALE_TO_ZERO_CONTEXT_JSON='null'
IDLE_SCALER_ISOLATION_ACTIVE=false
POST_INITIAL_SCALE_TO_ZERO_EXPECTED=true
EXCLUDED_SCENARIO_SET=""

export E2E_RUN_ID="$RUN_ID"
export E2E_ARTIFACTS_DIR="$ARTIFACTS_DIR"
export E2E_K6_ARTIFACTS_DIR="$K6_ARTIFACTS_DIR"
export E2E_FAILURE_ARTIFACTS_DIR="$FAILURE_ARTIFACTS_DIR"

max_int() {
	left="$1"
	right="$2"
	if [ "$left" -ge "$right" ]; then
		echo "$left"
	else
		echo "$right"
	fi
}

duration_to_seconds() {
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

csv_list_length() {
	list="$1"
	count=0
	for raw_item in $(printf '%s' "$list" | tr ',' ' '); do
		item="$(printf '%s' "$raw_item" | tr -d '[:space:]')"
		[ -n "$item" ] || continue
		count=$((count + 1))
	done
	printf '%s' "$count"
}

csv_list_item() {
	list="$1"
	target_index="$2"
	index=0
	for raw_item in $(printf '%s' "$list" | tr ',' ' '); do
		item="$(printf '%s' "$raw_item" | tr -d '[:space:]')"
		[ -n "$item" ] || continue
		index=$((index + 1))
		if [ "$index" -eq "$target_index" ]; then
			printf '%s' "$item"
			return 0
		fi
	done
	return 1
}

normalize_idle_scaler_isolation_mode() {
	mode="$1"
	case "$mode" in
		""|disabled)
			printf '%s' "disabled"
			;;
		stop-after-initial-scale-to-zero)
			printf '%s' "$mode"
			;;
		*)
			echo "Unsupported E2E_TARGET_IDLE_SCALER_ISOLATION_MODE: $mode" >&2
			exit 1
			;;
	esac
}

scenario_supported_with_idle_scaler_isolation() {
	case "$1" in
		idle-scaler-restart|restart-recovery|cleanup-consistency|consistency)
			return 1
			;;
		*)
			return 0
			;;
	esac
}

filter_scenario_set_for_idle_scaler_isolation() {
	requested_scenarios="$1"
	if [ "$IDLE_SCALER_ISOLATION_MODE" = "disabled" ]; then
		printf '%s' "$requested_scenarios"
		return 0
	fi

	filtered_scenarios=""
	for raw_scenario in $(printf '%s' "$requested_scenarios" | tr ',' ' '); do
		scenario_name="$(printf '%s' "$raw_scenario" | tr -d '[:space:]')"
		[ -n "$scenario_name" ] || continue
		if scenario_supported_with_idle_scaler_isolation "$scenario_name"; then
			filtered_scenarios="${filtered_scenarios}${filtered_scenarios:+,}$scenario_name"
		fi
	done

	printf '%s' "$filtered_scenarios"
}

excluded_scenario_set_for_idle_scaler_isolation() {
	requested_scenarios="$1"
	if [ "$IDLE_SCALER_ISOLATION_MODE" = "disabled" ]; then
		printf '%s' ""
		return 0
	fi

	excluded_scenarios=""
	for raw_scenario in $(printf '%s' "$requested_scenarios" | tr ',' ' '); do
		scenario_name="$(printf '%s' "$raw_scenario" | tr -d '[:space:]')"
		[ -n "$scenario_name" ] || continue
		if ! scenario_supported_with_idle_scaler_isolation "$scenario_name"; then
			excluded_scenarios="${excluded_scenarios}${excluded_scenarios:+,}$scenario_name"
		fi
	done

	printf '%s' "$excluded_scenarios"
}

configure_idle_scaler_isolation_mode() {
	IDLE_SCALER_ISOLATION_MODE="$(normalize_idle_scaler_isolation_mode "$IDLE_SCALER_ISOLATION_MODE")"
	export E2E_TARGET_IDLE_SCALER_ISOLATION_MODE="$IDLE_SCALER_ISOLATION_MODE"

	case "$IDLE_SCALER_ISOLATION_MODE" in
		disabled)
			POST_INITIAL_SCALE_TO_ZERO_EXPECTED=true
			EXCLUDED_SCENARIO_SET=""
			SCENARIO_SET="$REQUESTED_SCENARIO_SET"
			;;
		stop-after-initial-scale-to-zero)
			if [ "$IDLE_SCALER_PLACEMENT" != "nomad-system-job" ]; then
				echo "E2E_TARGET_IDLE_SCALER_ISOLATION_MODE=$IDLE_SCALER_ISOLATION_MODE requires E2E_TARGET_IDLE_SCALER_PLACEMENT=nomad-system-job" >&2
				exit 1
			fi
			POST_INITIAL_SCALE_TO_ZERO_EXPECTED=false
			EXCLUDED_SCENARIO_SET="$(excluded_scenario_set_for_idle_scaler_isolation "$REQUESTED_SCENARIO_SET")"
			SCENARIO_SET="$(filter_scenario_set_for_idle_scaler_isolation "$REQUESTED_SCENARIO_SET")"
			if [ -z "$SCENARIO_SET" ]; then
				echo "E2E_TARGET_IDLE_SCALER_ISOLATION_MODE=$IDLE_SCALER_ISOLATION_MODE excluded every requested scenario in E2E_SCENARIO_SET=$REQUESTED_SCENARIO_SET" >&2
				exit 1
			fi
			;;
	esac
}

append_jsonl() {
	file="$1"
	json_payload="$2"
	printf '%s\n' "$json_payload" >> "$file"
}

record_event() {
	event_name="$1"
	event_status="$2"
	event_context_json="${3:-"{}"}"
	event_payload="$(jq -nc \
		--arg event "$event_name" \
		--arg status "$event_status" \
		--arg at "$(timestamp_utc)" \
		--argjson timestamp_ms "$(timestamp_millis)" \
		--argjson event_context "$event_context_json" \
		'{event: $event, status: $status, at: $at, timestamp_ms: $timestamp_ms} + $event_context')"
	append_jsonl "$EVENTS_FILE" "$event_payload"
}

write_run_status() {
	status="$1"
	exit_code="$2"
	finished_at="$3"
	finished_at_ms="$4"

	jq -n \
		--arg run_id "$RUN_ID" \
		--arg status "$status" \
		--arg started_at "$RUN_STARTED_AT" \
		--argjson started_at_ms "$RUN_STARTED_AT_MS" \
		--arg finished_at "$finished_at" \
		--argjson finished_at_ms "$finished_at_ms" \
		--argjson exit_code "$exit_code" \
		--arg active_scenario "$ACTIVE_SCENARIO" \
		--arg artifacts_dir "$ARTIFACTS_DIR" \
		--arg events_file "$EVENTS_FILE" \
		'{
			run_id: $run_id,
			status: $status,
			started_at: $started_at,
			started_at_ms: $started_at_ms,
			finished_at: (if $finished_at == "" then null else $finished_at end),
			finished_at_ms: (if $finished_at_ms == 0 then null else $finished_at_ms end),
			exit_code: $exit_code,
			active_scenario: (if $active_scenario == "" then null else $active_scenario end),
			artifacts_dir: $artifacts_dir,
			events_file: $events_file
		}' > "$RUN_STATUS_FILE"
}

write_run_metadata() {
	jq -n \
		--arg run_id "$RUN_ID" \
		--arg started_at "$RUN_STARTED_AT" \
		--argjson started_at_ms "$RUN_STARTED_AT_MS" \
		--arg profile "${E2E_PROFILE:-}" \
		--arg profile_description "${E2E_PROFILE_DESCRIPTION:-}" \
		--arg automation_job_name "${E2E_AUTOMATION_JOB_NAME:-}" \
		--arg automation_smoke_job "${E2E_AUTOMATION_SMOKE_JOB:-}" \
		--arg automation_certification_job "${E2E_AUTOMATION_CERTIFICATION_JOB:-}" \
		--arg target_nomad_servers "${E2E_TARGET_NOMAD_SERVERS:-0}" \
		--arg target_nomad_clients "${E2E_TARGET_NOMAD_CLIENTS:-0}" \
		--arg target_consul_servers "${E2E_TARGET_CONSUL_SERVERS:-0}" \
		--arg target_traefik_replicas "${E2E_TARGET_TRAEFIK_REPLICAS:-0}" \
		--arg target_redis_nodes "${E2E_TARGET_REDIS_NODES:-0}" \
		--arg idle_scaler_placement "$IDLE_SCALER_PLACEMENT" \
		--arg idle_scaler_isolation_mode "$IDLE_SCALER_ISOLATION_MODE" \
		--arg workload_mix "${E2E_WORKLOAD_MIX_LABELS:-}" \
		--arg workload_fast_api_count "${E2E_WORKLOAD_FAST_API_COUNT:-0}" \
		--arg workload_slow_start_count "${E2E_WORKLOAD_SLOW_START_COUNT:-0}" \
		--arg workload_dependency_sensitive_count "${E2E_WORKLOAD_DEPENDENCY_SENSITIVE_COUNT:-0}" \
		--arg job_count "$JOB_COUNT" \
		--arg traffic_scenario "$TRAFFIC_SCENARIO" \
		--arg traffic_shape "$TRAFFIC_SHAPE_LIST" \
		--arg k6_target_mode "$K6_TARGET_MODE" \
		--arg soak_cycles "$SOAK_CYCLES" \
		--arg scenario_set "$SCENARIO_SET" \
		--arg request_timeout "$REQUEST_TIMEOUT" \
		--arg idle_timeout "$IDLE_TIMEOUT" \
		--arg idle_check_interval "$IDLE_CHECK_INTERVAL" \
		--arg startup_ready_timeout "$startup_ready_timeout" \
		--arg nomad_wake_timeout "$nomad_wake_timeout" \
		--arg consul_checks_timeout "$consul_checks_timeout" \
		--arg consul_cleanup_timeout "$consul_cleanup_timeout" \
		--arg store_type "$STORE_TYPE" \
		--arg warmup_vus "${E2E_WARMUP_VUS:-0}" \
		--arg warmup_duration "${E2E_WARMUP_DURATION:-}" \
		--arg burst_vus "${E2E_BURST_VUS:-0}" \
		--arg burst_duration "${E2E_BURST_DURATION:-}" \
		--arg storm_start_rate "${E2E_STORM_START_RATE:-0}" \
		--arg storm_rate "${E2E_STORM_RATE:-0}" \
		--arg storm_duration "${E2E_STORM_DURATION:-}" \
		--arg storm_preallocated_vus "${E2E_STORM_PREALLOCATED_VUS:-0}" \
		--arg storm_max_vus "${E2E_STORM_MAX_VUS:-0}" \
		--arg requested_scenario_set "$REQUESTED_SCENARIO_SET" \
		--arg excluded_scenario_set "$EXCLUDED_SCENARIO_SET" \
		--arg gate_traffic_success_rate "${E2E_GATE_TRAFFIC_SUCCESS_RATE:-}" \
		--arg gate_wake_p95_ms "${E2E_GATE_WAKE_P95_MS:-}" \
		--arg gate_wake_p99_ms "${E2E_GATE_WAKE_P99_MS:-}" \
		--arg gate_scale_to_zero_max_seconds "${E2E_GATE_SCALE_TO_ZERO_MAX_SECONDS:-}" \
		--arg gate_dependency_ready_max_seconds "${E2E_GATE_DEPENDENCY_READY_MAX_SECONDS:-}" \
		--argjson post_initial_scale_to_zero_expected "$POST_INITIAL_SCALE_TO_ZERO_EXPECTED" \
		--argjson idle_scaler_isolation_active "$IDLE_SCALER_ISOLATION_ACTIVE" \
		--arg artifacts_dir "$ARTIFACTS_DIR" \
		--arg generated_dir "$GENERATED_DIR" \
		--arg workload_manifest_file "$WORKLOAD_MANIFEST_FILE" \
		--arg release_gates_file "release-gates.json" \
		--arg release_gates_summary_file "release-gates-summary.txt" \
		--arg failure_artifacts_dir "failures" \
		'
		def csv:
			split(",")
			| map(gsub("^\\s+|\\s+$"; ""))
			| map(select(length > 0));

		{
			run_id: $run_id,
			started_at: $started_at,
			started_at_ms: $started_at_ms,
			profile: {
				name: $profile,
				description: $profile_description,
				automation_job_name: $automation_job_name,
				smoke_job: $automation_smoke_job,
				certification_job: $automation_certification_job
			},
			topology: {
				nomad_servers: ($target_nomad_servers | tonumber),
				nomad_clients: ($target_nomad_clients | tonumber),
				consul_servers: ($target_consul_servers | tonumber),
				traefik_replicas: ($target_traefik_replicas | tonumber),
				redis_nodes: ($target_redis_nodes | tonumber),
				idle_scaler_placement: $idle_scaler_placement
			},
			idle_scaler: {
				placement: $idle_scaler_placement,
				isolation_mode: $idle_scaler_isolation_mode,
				isolation_active: $idle_scaler_isolation_active,
				isolation_activation_phase: (if $idle_scaler_isolation_mode == "disabled" then null else "after-initial-scale-to-zero" end),
				post_initial_scale_to_zero_expected: $post_initial_scale_to_zero_expected
			},
			workload: {
				mix_labels: ($workload_mix | csv),
				job_count: ($job_count | tonumber),
				fast_api_count: ($workload_fast_api_count | tonumber),
				slow_start_count: ($workload_slow_start_count | tonumber),
				dependency_sensitive_count: ($workload_dependency_sensitive_count | tonumber)
			},
			traffic: {
				default_scenario: $traffic_scenario,
				shapes: ($traffic_shape | csv),
				k6_target_mode: $k6_target_mode,
				soak_cycles: ($soak_cycles | tonumber),
				request_timeout: $request_timeout,
				warmup: {
					vus: ($warmup_vus | tonumber),
					duration: $warmup_duration
				},
				burst: {
					vus: ($burst_vus | tonumber),
					duration: $burst_duration
				},
				storm: {
					start_rate: ($storm_start_rate | tonumber),
					rate: ($storm_rate | tonumber),
					duration: $storm_duration,
					preallocated_vus: ($storm_preallocated_vus | tonumber),
					max_vus: ($storm_max_vus | tonumber)
				}
			},
			scenarios: ($scenario_set | csv),
			scenario_plan: {
				requested: ($requested_scenario_set | csv),
				effective: ($scenario_set | csv),
				excluded: ($excluded_scenario_set | csv)
			},
			store_type: $store_type,
			timeouts: {
				idle_timeout: $idle_timeout,
				idle_check_interval: $idle_check_interval,
				startup_ready_timeout: $startup_ready_timeout,
				nomad_wake_timeout: $nomad_wake_timeout,
				consul_checks_timeout: $consul_checks_timeout,
				consul_cleanup_timeout: $consul_cleanup_timeout
			},
			gates: {
				traffic_success_rate: $gate_traffic_success_rate,
				wake_p95_ms: $gate_wake_p95_ms,
				wake_p99_ms: $gate_wake_p99_ms,
				scale_to_zero_max_seconds: $gate_scale_to_zero_max_seconds,
				dependency_ready_max_seconds: $gate_dependency_ready_max_seconds
			},
			directories: {
				artifacts: $artifacts_dir,
				k6: "k6",
				state: "state",
				scenarios: "scenarios",
				workloads: "workloads",
				cleanup: "cleanup",
				failures: $failure_artifacts_dir,
				release_gates: $release_gates_file,
				release_gates_summary: $release_gates_summary_file,
				generated: $generated_dir,
				workload_manifest_file: $workload_manifest_file
			}
		}' > "$RUN_METADATA_FILE"
}

copy_file_if_present() {
	source_file="$1"
	destination_file="$2"
	if [ -f "$source_file" ]; then
		cp "$source_file" "$destination_file"
	fi
}

persist_generated_artifacts() {
	mkdir -p "$WORKLOAD_ARTIFACTS_DIR" "$WORKLOAD_ARTIFACTS_DIR/jobs"
	copy_file_if_present "$WORKLOAD_MANIFEST_FILE" "$WORKLOAD_ARTIFACTS_DIR/workload-manifest.tsv"

	for generated_file in "$GENERATED_JOBS_DIR"/*.nomad "$GENERATED_DIR"/idle-scaler.nomad; do
		[ -f "$generated_file" ] || continue
		cp "$generated_file" "$WORKLOAD_ARTIFACTS_DIR/jobs/$(basename "$generated_file")"
	done
}

nomad_get() {
	path="$1"
	if [ -n "${NOMAD_TOKEN:-}" ]; then
		curl -fsS -H "X-Nomad-Token: $NOMAD_TOKEN" "$NOMAD_ADDR$path"
	else
		curl -fsS "$NOMAD_ADDR$path"
	fi
}

capture_service_failure_bundle() {
	service_name="$1"
	job_name="${2:-$service_name}"
	failure_reason="$3"
	failure_message="${4:-}"
	failure_context_json="${5:-{}}"
	failure_metadata_response="${6:-}"
	failure_request_output="${7:-}"

	[ -n "${E2E_ARTIFACTS_DIR:-}" ] || return 0

	E2E_FAILURE_MESSAGE="$failure_message" \
	E2E_FAILURE_CONTEXT_JSON="${failure_context_json:-{}}" \
	E2E_FAILURE_METADATA_RESPONSE="$failure_metadata_response" \
	E2E_FAILURE_REQUEST_OUTPUT="$failure_request_output" \
		"$ROOT_DIR"/e2e/scripts/capture-service-failure-bundle.sh "$service_name" "$job_name" "$failure_reason" || true
}

resolve_idle_scaler_observability_url() {
	case "$IDLE_SCALER_PLACEMENT" in
		docker-compose-service)
			printf '%s' "http://idle-scaler:9108"
			return 0
			;;
	esac

	service_json="$(consul_get "/v1/catalog/service/idle-scaler" 2>/dev/null || true)"
	[ -n "$service_json" ] || return 1

	address="$(printf '%s' "$service_json" | jq -r 'if length == 0 then empty else (.[0].ServiceAddress // .[0].Address // "") end')"
	port="$(printf '%s' "$service_json" | jq -r 'if length == 0 then empty else (.[0].ServicePort | tostring) end')"
	[ -n "$address" ] && [ -n "$port" ] || return 1

	printf 'http://%s:%s' "$address" "$port"
}

capture_state_snapshot() {
	snapshot_label_name="$1"
	snapshot_slug="$(slugify "$snapshot_label_name")"
	snapshot_dir="$STATE_ARTIFACTS_DIR/$snapshot_slug"
	snapshot_relpath="state/$snapshot_slug"

	mkdir -p \
		"$snapshot_dir" \
		"$snapshot_dir/consul" \
		"$snapshot_dir/nomad" \
		"$snapshot_dir/redis" \
		"$snapshot_dir/idle-scaler"

	jq -n \
		--arg snapshot_label "$snapshot_label_name" \
		--arg captured_at "$(timestamp_utc)" \
		--argjson captured_at_ms "$(timestamp_millis)" \
		'{
			"label": $snapshot_label,
			captured_at: $captured_at,
			captured_at_ms: $captured_at_ms
		}' > "$snapshot_dir/metadata.json"

	set +e
	consul_get "/v1/catalog/services" > "$snapshot_dir/consul/catalog-services.json"
	consul_get "/v1/health/state/any" > "$snapshot_dir/consul/health-state-any.json"
	consul_get "/v1/catalog/service/idle-scaler" > "$snapshot_dir/consul/idle-scaler-service.json"
	nomad_get "/v1/status/leader" > "$snapshot_dir/nomad/leader.txt"
	nomad_get "/v1/nodes" > "$snapshot_dir/nomad/nodes.json"
	nomad_get "/v1/jobs" > "$snapshot_dir/nomad/jobs.json"
	nomad_get "/v1/allocations" > "$snapshot_dir/nomad/allocations.json"
	E2E_REDIS_INFO_FORMAT=text "$ROOT_DIR"/e2e/scripts/collect-redis-info.sh "$snapshot_label_name" > "$snapshot_dir/redis/info.txt"
	E2E_REDIS_INFO_FORMAT=json "$ROOT_DIR"/e2e/scripts/collect-redis-info.sh "$snapshot_label_name" > "$snapshot_dir/redis/info.json"
	"$ROOT_DIR"/e2e/scripts/collect-redis-activity.sh "$snapshot_label_name" json > "$snapshot_dir/redis/activity.json"

	idle_scaler_url="$(resolve_idle_scaler_observability_url 2>/dev/null || true)"
	if [ -n "$idle_scaler_url" ]; then
		printf '%s\n' "$idle_scaler_url" > "$snapshot_dir/idle-scaler/endpoint.txt"
		curl -fsS "$idle_scaler_url/healthz" > "$snapshot_dir/idle-scaler/healthz.txt"
		curl -fsS "$idle_scaler_url/metrics" > "$snapshot_dir/idle-scaler/metrics.txt"
	else
		printf 'unavailable\n' > "$snapshot_dir/idle-scaler/endpoint.txt"
	fi
	set -e

	record_event "state-snapshot" "captured" "$(jq -nc --arg snapshot_label "$snapshot_label_name" --arg snapshot_dir "$snapshot_relpath" '{"label": $snapshot_label, snapshot_dir: $snapshot_dir}')"
}

write_consul_cleanup_artifact() {
	label="$1"
	status="$2"
	duration_ms="$3"
	cleanup_context_json="${4:-{}}"
	cleanup_file="$CLEANUP_ARTIFACTS_DIR/$(slugify "$label").json"

	jq -n \
		--arg cleanup_label "$label" \
		--arg status "$status" \
		--arg captured_at "$(timestamp_utc)" \
		--argjson captured_at_ms "$(timestamp_millis)" \
		--argjson duration_ms "${duration_ms:-0}" \
		--arg expected_services_json "${CONSUL_BASELINE_SERVICE_NAMES_JSON:-[]}" \
		--arg expected_check_counts_json "${CONSUL_BASELINE_CHECK_COUNTS_JSON:-[]}" \
		--arg current_services_json "${CURRENT_NONWORKLOAD_SERVICES_JSON:-[]}" \
		--arg current_check_counts_json "${CURRENT_NONWORKLOAD_CHECK_COUNTS_JSON:-[]}" \
		--arg stale_workload_services "${CURRENT_WORKLOAD_SERVICES:-}" \
		--arg stale_workload_checks "${CURRENT_WORKLOAD_CHECKS:-}" \
		--arg cleanup_context_json "${cleanup_context_json:-{}}" \
		'{
			"label": $cleanup_label,
			status: $status,
			captured_at: $captured_at,
			captured_at_ms: $captured_at_ms,
			duration_ms: $duration_ms,
			expected_nonworkload_services: ($expected_services_json | fromjson? // []),
			expected_nonworkload_check_counts: ($expected_check_counts_json | fromjson? // []),
			current_nonworkload_services: ($current_services_json | fromjson? // []),
			current_nonworkload_check_counts: ($current_check_counts_json | fromjson? // []),
			stale_workload_services: ($stale_workload_services | split("\n") | map(select(length > 0))),
			stale_workload_checks: ($stale_workload_checks | split("\n") | map(select(length > 0)))
		} + ($cleanup_context_json | fromjson? // {})' > "$cleanup_file"
}

cleanup_artifact_relpath() {
	label="$1"
	printf 'cleanup/%s.json' "$(slugify "$label")"
}

fallback_cleanup_correlation_json() {
	error_message="${1:-cleanup correlation unavailable}"

	jq -nc \
		--arg generated_at "$(timestamp_utc)" \
		--argjson idle_timeout_seconds "$idle_timeout_seconds" \
		--arg error_message "$error_message" \
		'{
			generated_at: $generated_at,
			idle_timeout_seconds: $idle_timeout_seconds,
			errors: (if $error_message == "" then [] else [$error_message] end),
			sources: {},
			stale_workload_detail_count: 0,
			diagnosis_summary: {
				cause_counts: {},
				active_nomad_service_count: 0,
				inactive_nomad_service_count: 0,
				active_nomad_services: [],
				inactive_nomad_services: [],
				services_by_cause: {}
			},
			stale_workload_details: []
		}'
}

build_consul_cleanup_context_from_snapshot() {
	snapshot_label_name="$1"
	snapshot_slug="$(slugify "$snapshot_label_name")"
	snapshot_dir="$STATE_ARTIFACTS_DIR/$snapshot_slug"
	snapshot_relpath="state/$snapshot_slug"

	if correlation_output="$("$ROOT_DIR"/e2e/scripts/correlate-consul-cleanup.sh \
		"$snapshot_dir" \
		"$WORKLOAD_MANIFEST_FILE" \
		"$WORKLOAD_PREFIX" \
		"$idle_timeout_seconds" 2>&1)"; then
		if printf '%s' "$correlation_output" | jq -e . >/dev/null 2>&1; then
			correlation_json="$correlation_output"
		else
			correlation_json="$(fallback_cleanup_correlation_json "invalid cleanup correlation JSON")"
		fi
	else
		correlation_json="$(fallback_cleanup_correlation_json "$correlation_output")"
	fi

	jq -nc \
		--arg snapshot_dir "$snapshot_relpath" \
		--arg cleanup_correlation_json "${correlation_json:-{}}" \
		'{
			state_snapshot_dir: $snapshot_dir,
			cleanup_correlation: ($cleanup_correlation_json | fromjson? // {})
		}'
}

cleanup_event_context_json() {
	label="$1"
	duration_ms="$2"
	cleanup_context_json="${3:-{}}"
	cleanup_artifact="$(cleanup_artifact_relpath "$label")"

	jq -nc \
		--arg cleanup_label "$label" \
		--arg cleanup_artifact "$cleanup_artifact" \
		--arg stale_workload_services "${CURRENT_WORKLOAD_SERVICES:-}" \
		--arg stale_workload_checks "${CURRENT_WORKLOAD_CHECKS:-}" \
		--argjson duration_ms "${duration_ms:-0}" \
		--arg cleanup_context_json "${cleanup_context_json:-{}}" \
		'($cleanup_context_json | fromjson? // {}) as $cleanup_context
		| {
			"label": $cleanup_label,
			duration_ms: $duration_ms,
			cleanup_artifact: $cleanup_artifact,
			stale_workload_service_count: ($stale_workload_services | split("\n") | map(select(length > 0)) | length),
			stale_workload_check_count: ($stale_workload_checks | split("\n") | map(select(length > 0)) | length)
		}
		+ (if ($cleanup_context.state_snapshot_dir // "") == "" then {} else {state_snapshot_dir: $cleanup_context.state_snapshot_dir} end)
		+ (if ($cleanup_context.cleanup_correlation // null) == null then {} else {
			cleanup_diagnosis_summary: ($cleanup_context.cleanup_correlation.diagnosis_summary // {}),
			cleanup_sources: ($cleanup_context.cleanup_correlation.sources // {})
		} end)
		+ (if (($cleanup_context.cleanup_correlation.errors // []) | length) == 0 then {} else {
			cleanup_correlation_errors: ($cleanup_context.cleanup_correlation.errors // [])
		} end)'
}

on_exit() {
	exit_code="$?"
	[ "$ARTIFACTS_READY" -eq 1 ] || return 0

	set +e
	if [ "$exit_code" -eq 0 ]; then
		final_status="passed"
	else
		final_status="failed"
	fi

	if [ -n "$ACTIVE_SCENARIO" ]; then
		record_event "scenario-aborted" "$final_status" "$(jq -nc --arg scenario "$ACTIVE_SCENARIO" '{scenario: $scenario}')"
	fi

	capture_state_snapshot "run-final"
	record_event "run-complete" "$final_status" "$(jq -nc --argjson exit_code "$exit_code" '{exit_code: $exit_code}')"
	write_run_status "$final_status" "$exit_code" "$(timestamp_utc)" "$(timestamp_millis)"

	E2E_RELEASE_GATES_FILE="$RELEASE_GATES_FILE" \
	E2E_RELEASE_GATES_SUMMARY_FILE="$RELEASE_GATES_SUMMARY_FILE" \
		"$ROOT_DIR"/e2e/scripts/evaluate-release-gates.sh "$ARTIFACTS_DIR"
	release_gate_exit_code="$?"
	if [ "$exit_code" -eq 0 ] && [ "$release_gate_exit_code" -ne 0 ]; then
		trap - EXIT
		exit "$release_gate_exit_code"
	fi
}

traffic_shape_count="$(csv_list_length "$TRAFFIC_SHAPE_LIST")"
idle_timeout_seconds="$(duration_to_seconds "$IDLE_TIMEOUT")"
idle_check_interval_seconds="$(duration_to_seconds "$IDLE_CHECK_INTERVAL")"
min_scale_down_age_seconds="$(duration_to_seconds "$MIN_SCALE_DOWN_AGE")"
scale_down_guard_seconds="$(max_int "$idle_timeout_seconds" "$min_scale_down_age_seconds")"
idle_wait_seconds="$(( scale_down_guard_seconds + idle_check_interval_seconds + 15 ))"
request_timeout_seconds="$(duration_to_seconds "$REQUEST_TIMEOUT")"
startup_ready_timeout="${E2E_STARTUP_READY_TIMEOUT:-${E2E_CONSUL_SERVICES_TIMEOUT:-$(max_int $((JOB_COUNT * 3)) 120)}}"
nomad_wake_timeout="${E2E_NOMAD_WAKE_TIMEOUT:-$(max_int "$JOB_COUNT" 60)}"
consul_checks_timeout="${E2E_CONSUL_CHECKS_TIMEOUT:-120}"
consul_cleanup_timeout="$(max_int "$startup_ready_timeout" "$(max_int "$idle_wait_seconds" "$consul_checks_timeout")")"

configure_idle_scaler_isolation_mode

submit_job() {
	job_file="$1"
	nomad job run -detach -address="$NOMAD_ADDR" "$job_file"
}

wait_for_compose_idle_scaler() {
	WAIT_TIMEOUT_SECONDS="$startup_ready_timeout" \
		"$ROOT_DIR"/e2e/scripts/wait-for-http.sh "http://idle-scaler:9108/healthz" idle-scaler
}

submit_nomad_idle_scaler() {
	job_file="${GENERATED_DIR}/idle-scaler.nomad"
	"$ROOT_DIR"/e2e/scripts/render-idle-scaler-job.sh
	persist_generated_artifacts
	submit_job "$job_file"
	"$ROOT_DIR"/e2e/scripts/wait-for-nomad-job.sh "idle-scaler-e2e" "$IDLE_SCALER_EXPECTED_RUNNING" "$startup_ready_timeout"
	"$ROOT_DIR"/e2e/scripts/wait-for-consul-checks.sh "_nomad-check-" "$IDLE_SCALER_EXPECTED_RUNNING" "$startup_ready_timeout" "idle-scaler"
}

prepare_idle_scaler() {
	case "$IDLE_SCALER_PLACEMENT" in
		docker-compose-service)
			printf "${CYAN}=== Wait for docker-compose idle-scaler ===${NC}\n"
			wait_for_compose_idle_scaler
			;;
		nomad-system-job)
			printf "${CYAN}=== Submit Nomad idle-scaler system job ===${NC}\n"
			submit_nomad_idle_scaler
			;;
		*)
			echo "Unsupported E2E_TARGET_IDLE_SCALER_PLACEMENT: $IDLE_SCALER_PLACEMENT" >&2
			exit 1
			;;
	esac
}

activate_idle_scaler_isolation_mode() {
	case "$IDLE_SCALER_ISOLATION_MODE" in
		disabled)
			return 0
			;;
		stop-after-initial-scale-to-zero)
			printf "${CYAN}=== Activate idle-scaler isolation mode ===${NC}\n"
			printf "Stopping Nomad idle-scaler after initial scale-to-zero; later scaler-dependent phases stay disabled for this run.\n"
			purge_nomad_job "idle-scaler-e2e"
			wait_for_nomad_job_inactive "idle-scaler-e2e"
			IDLE_SCALER_ISOLATION_ACTIVE=true
			write_run_metadata
			record_event "idle-scaler-isolation" "active" "$(jq -nc \
				--arg mode "$IDLE_SCALER_ISOLATION_MODE" \
				--arg placement "$IDLE_SCALER_PLACEMENT" \
				--arg requested_scenario_set "$REQUESTED_SCENARIO_SET" \
				--arg effective_scenario_set "$SCENARIO_SET" \
				--arg excluded_scenario_set "$EXCLUDED_SCENARIO_SET" \
				'{
					mode: $mode,
					placement: $placement,
					activation_phase: "after-initial-scale-to-zero",
					requested_scenario_set: $requested_scenario_set,
					effective_scenario_set: $effective_scenario_set,
					excluded_scenario_set: (if $excluded_scenario_set == "" then null else $excluded_scenario_set end)
				}')"
			capture_state_snapshot "idle-scaler-isolation-active"
			;;
	esac
}

traffic_shape_for_cycle() {
	cycle="$1"
	if [ "$traffic_shape_count" -le 0 ]; then
		printf '%s' "$TRAFFIC_SCENARIO"
		return 0
	fi

	shape_index=$(( ((cycle - 1) % traffic_shape_count) + 1 ))
	if ! csv_list_item "$TRAFFIC_SHAPE_LIST" "$shape_index"; then
		printf '%s' "$TRAFFIC_SCENARIO"
	fi
}

fixed_service_name_for_cycle() {
	cycle="$1"
	printf 'echo-s2z-%04d' "$(( ((cycle - 1) % JOB_COUNT) + 1 ))"
}

consul_get() {
	path="$1"
	if [ -n "${CONSUL_HTTP_TOKEN:-}" ]; then
		curl -fsS -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" "$CONSUL_ADDR$path"
	else
		curl -fsS "$CONSUL_ADDR$path"
	fi
}

nomad_delete() {
	path="$1"
	if [ -n "${NOMAD_TOKEN:-}" ]; then
		curl -fsS -X DELETE -H "X-Nomad-Token: $NOMAD_TOKEN" "$NOMAD_ADDR$path" >/dev/null
	else
		curl -fsS -X DELETE "$NOMAD_ADDR$path" >/dev/null
	fi
}

nomad_job_status() {
	job_name="$1"
	if [ -n "${NOMAD_TOKEN:-}" ]; then
		response="$(curl -sS -H "X-Nomad-Token: $NOMAD_TOKEN" -w '
%{http_code}' "$NOMAD_ADDR/v1/job/$job_name" || true)"
	else
		response="$(curl -sS -w '
%{http_code}' "$NOMAD_ADDR/v1/job/$job_name" || true)"
	fi

	http_code="$(printf '%s' "$response" | tail -n 1)"
	body="$(printf '%s' "$response" | sed '$d')"

	case "$http_code" in
		404)
			printf '%s' "not-found"
			;;
		2*)
			printf '%s' "$body" | jq -r '.Status | ascii_downcase'
			;;
		*)
			echo "Unexpected Nomad response for $job_name: HTTP $http_code" >&2
			return 1
			;;
	esac
}

capture_consul_baseline() {
	catalog_json="$(consul_get "/v1/catalog/services")"
	checks_json="$(consul_get "/v1/health/state/any")"

	CONSUL_BASELINE_SERVICE_NAMES_JSON="$(printf '%s' "$catalog_json" | jq -c --arg prefix "$WORKLOAD_PREFIX" '[keys[] | select(startswith($prefix) | not)]')"
	CONSUL_BASELINE_CHECK_COUNTS_JSON="$(printf '%s' "$checks_json" | jq -c --arg prefix "$WORKLOAD_PREFIX" '[.[] | select((.ServiceName // "") != "" and ((.ServiceName // "") | startswith($prefix) | not))] | group_by(.ServiceName) | map({service: .[0].ServiceName, count: length}) | sort_by(.service)')"

	printf "${CYAN}=== Captured Consul baseline ===${NC}\n"
	printf "  services=%s\n" "$CONSUL_BASELINE_SERVICE_NAMES_JSON"
	printf "  service_check_counts=%s\n" "$CONSUL_BASELINE_CHECK_COUNTS_JSON"

	jq -n \
		--arg captured_at "$(timestamp_utc)" \
		--argjson captured_at_ms "$(timestamp_millis)" \
		--argjson services "$CONSUL_BASELINE_SERVICE_NAMES_JSON" \
		--argjson service_check_counts "$CONSUL_BASELINE_CHECK_COUNTS_JSON" \
		'{
			captured_at: $captured_at,
			captured_at_ms: $captured_at_ms,
			nonworkload_services: $services,
			nonworkload_service_check_counts: $service_check_counts
		}' > "$CONSUL_BASELINE_FILE"
}

set_consul_cleanup_state_from_json() {
	catalog_json="$1"
	checks_json="$2"
	CURRENT_NONWORKLOAD_SERVICES_JSON="$(printf '%s' "$catalog_json" | jq -c --arg prefix "$WORKLOAD_PREFIX" '[keys[] | select(startswith($prefix) | not)]')"
	CURRENT_WORKLOAD_SERVICES="$(printf '%s' "$catalog_json" | jq -r --arg prefix "$WORKLOAD_PREFIX" 'keys[] | select(startswith($prefix))')"
	CURRENT_NONWORKLOAD_CHECK_COUNTS_JSON="$(printf '%s' "$checks_json" | jq -c --arg prefix "$WORKLOAD_PREFIX" '[.[] | select((.ServiceName // "") != "" and ((.ServiceName // "") | startswith($prefix) | not))] | group_by(.ServiceName) | map({service: .[0].ServiceName, count: length}) | sort_by(.service)')"
	CURRENT_WORKLOAD_CHECKS="$(printf '%s' "$checks_json" | jq -r --arg prefix "$WORKLOAD_PREFIX" '.[] | select((.ServiceName // "") | startswith($prefix)) | "\(.CheckID) service=\(.ServiceName // "") status=\(.Status)"')"
}

capture_current_consul_cleanup_state() {
	catalog_json="$(consul_get "/v1/catalog/services")"
	checks_json="$(consul_get "/v1/health/state/any")"
	set_consul_cleanup_state_from_json "$catalog_json" "$checks_json"
}

consul_workloads_drained() {
	[ -z "$CURRENT_WORKLOAD_SERVICES" ] && [ -z "$CURRENT_WORKLOAD_CHECKS" ]
}

consul_nonworkload_matches_baseline() {
	[ "$CURRENT_NONWORKLOAD_SERVICES_JSON" = "$CONSUL_BASELINE_SERVICE_NAMES_JSON" ] \
		&& [ "$CURRENT_NONWORKLOAD_CHECK_COUNTS_JSON" = "$CONSUL_BASELINE_CHECK_COUNTS_JSON" ]
}

load_consul_cleanup_state_from_snapshot() {
	snapshot_dir="$1"
	catalog_file="$snapshot_dir/consul/catalog-services.json"
	checks_file="$snapshot_dir/consul/health-state-any.json"

	[ -s "$catalog_file" ] || return 1
	[ -s "$checks_file" ] || return 1

	catalog_json="$(cat "$catalog_file")"
	checks_json="$(cat "$checks_file")"
	set_consul_cleanup_state_from_json "$catalog_json" "$checks_json"
}

wait_for_consul_cleanup() {
	label="$1"
	start="$(date +%s)"
	start_ms="$(timestamp_millis)"

	while true; do
		capture_current_consul_cleanup_state

		if consul_workloads_drained && consul_nonworkload_matches_baseline; then
			end_ms="$(timestamp_millis)"
			CONSUL_CLEANUP_LAST_DURATION_MS=$((end_ms - start_ms))
			cleanup_context_json='{}'
			write_consul_cleanup_artifact "$label" "passed" "$CONSUL_CLEANUP_LAST_DURATION_MS" "$cleanup_context_json"
			record_event "consul-cleanup" "passed" "$(cleanup_event_context_json "$label" "$CONSUL_CLEANUP_LAST_DURATION_MS" "$cleanup_context_json")"
			echo "Consul returned to baseline after ${label}"
			return 0
		fi

		now="$(date +%s)"
		if [ $((now - start)) -ge "$consul_cleanup_timeout" ]; then
			end_ms="$(timestamp_millis)"
			CONSUL_CLEANUP_LAST_DURATION_MS=$((end_ms - start_ms))
			cleanup_snapshot_label="${label}-consul-cleanup-timeout"
			cleanup_snapshot_dir="$STATE_ARTIFACTS_DIR/$(slugify "$cleanup_snapshot_label")"
			capture_state_snapshot "$cleanup_snapshot_label"
			load_consul_cleanup_state_from_snapshot "$cleanup_snapshot_dir" || true
			cleanup_context_json="$(build_consul_cleanup_context_from_snapshot "$cleanup_snapshot_label")"
			write_consul_cleanup_artifact "$label" "timed_out" "$CONSUL_CLEANUP_LAST_DURATION_MS" "$cleanup_context_json"
			record_event "consul-cleanup" "timed_out" "$(cleanup_event_context_json "$label" "$CONSUL_CLEANUP_LAST_DURATION_MS" "$cleanup_context_json")"
			echo "Timed out waiting for Consul cleanup after ${label}" >&2
			echo "Expected baseline services: ${CONSUL_BASELINE_SERVICE_NAMES_JSON}" >&2
			echo "Current non-workload services: ${CURRENT_NONWORKLOAD_SERVICES_JSON}" >&2
			echo "Expected non-workload check counts: ${CONSUL_BASELINE_CHECK_COUNTS_JSON}" >&2
			echo "Current non-workload check counts: ${CURRENT_NONWORKLOAD_CHECK_COUNTS_JSON}" >&2
			if [ -n "$CURRENT_WORKLOAD_SERVICES" ]; then
				echo "Stale workload services:" >&2
				printf '%s\n' "$CURRENT_WORKLOAD_SERVICES" >&2
			fi
			if [ -n "$CURRENT_WORKLOAD_CHECKS" ]; then
				echo "Stale workload checks:" >&2
				printf '%s\n' "$CURRENT_WORKLOAD_CHECKS" >&2
			fi
			exit 1
		fi

		sleep 2
	done
}

wait_for_workload_consul_cleanup() {
	label="$1"
	start="$(date +%s)"
	start_ms="$(timestamp_millis)"

	while true; do
		capture_current_consul_cleanup_state

		if consul_workloads_drained; then
			end_ms="$(timestamp_millis)"
			CONSUL_WORKLOAD_CLEANUP_LAST_DURATION_MS=$((end_ms - start_ms))
			echo "Workload services removed from Consul after ${label}"
			return 0
		fi

		now="$(date +%s)"
		if [ $((now - start)) -ge "$consul_cleanup_timeout" ]; then
			end_ms="$(timestamp_millis)"
			CONSUL_WORKLOAD_CLEANUP_LAST_DURATION_MS=$((end_ms - start_ms))
			CONSUL_CLEANUP_LAST_DURATION_MS=$CONSUL_WORKLOAD_CLEANUP_LAST_DURATION_MS
			cleanup_snapshot_label="${label}-consul-cleanup-timeout"
			cleanup_snapshot_dir="$STATE_ARTIFACTS_DIR/$(slugify "$cleanup_snapshot_label")"
			capture_state_snapshot "$cleanup_snapshot_label"
			load_consul_cleanup_state_from_snapshot "$cleanup_snapshot_dir" || true
			cleanup_context_json="$(build_consul_cleanup_context_from_snapshot "$cleanup_snapshot_label")"
			write_consul_cleanup_artifact "$label" "timed_out" "$CONSUL_CLEANUP_LAST_DURATION_MS" "$cleanup_context_json"
			record_event "consul-cleanup" "timed_out" "$(cleanup_event_context_json "$label" "$CONSUL_CLEANUP_LAST_DURATION_MS" "$cleanup_context_json")"
			echo "Timed out waiting for workload Consul cleanup after ${label}" >&2
			echo "Expected baseline services: ${CONSUL_BASELINE_SERVICE_NAMES_JSON}" >&2
			echo "Current non-workload services: ${CURRENT_NONWORKLOAD_SERVICES_JSON}" >&2
			echo "Expected non-workload check counts: ${CONSUL_BASELINE_CHECK_COUNTS_JSON}" >&2
			echo "Current non-workload check counts: ${CURRENT_NONWORKLOAD_CHECK_COUNTS_JSON}" >&2
			if [ -n "$CURRENT_WORKLOAD_SERVICES" ]; then
				echo "Stale workload services:" >&2
				printf '%s\n' "$CURRENT_WORKLOAD_SERVICES" >&2
			fi
			if [ -n "$CURRENT_WORKLOAD_CHECKS" ]; then
				echo "Stale workload checks:" >&2
				printf '%s\n' "$CURRENT_WORKLOAD_CHECKS" >&2
			fi
			exit 1
		fi

		sleep 2
	done
}

require_workload_manifest() {
	if [ ! -s "$WORKLOAD_MANIFEST_FILE" ]; then
		echo "Expected workload manifest at $WORKLOAD_MANIFEST_FILE" >&2
		exit 1
	fi
}

first_manifest_entry() {
	awk 'NR == 1 { print; exit }' "$WORKLOAD_MANIFEST_FILE"
}

manifest_entry_for_class() {
	workload_class="$1"
	awk -F'|' -v workload_class="$workload_class" '$3 == workload_class { print; exit }' "$WORKLOAD_MANIFEST_FILE"
}

manifest_class_for_job() {
	job_name="$1"
	awk -F'|' -v job_name="$job_name" '$1 == job_name { print $3; exit }' "$WORKLOAD_MANIFEST_FILE"
}

manifest_job_spec_key() {
	job_name="$1"
	awk -F'|' -v job_name="$job_name" '$1 == job_name { print $5; exit }' "$WORKLOAD_MANIFEST_FILE"
}

select_revival_target_entry() {
	entry="$(manifest_entry_for_class "fast-api")"
	if [ -z "$entry" ]; then
		entry="$(first_manifest_entry)"
	fi
	printf '%s' "$entry"
}

request_workload_metadata() {
	service_name="$1"
	expected_class="$2"
	host_name="${service_name}.localhost"
	request_url="$TRAEFIK_URL/metadata"

	if response="$(curl -fsS --max-time "$request_timeout_seconds" -H "Host: $host_name" "$request_url" 2>&1)"; then
		:
	else
		curl_exit_code="$?"
		failure_message="Failed to request metadata for $service_name from $request_url (curl_exit=$curl_exit_code)"
		echo "$failure_message" >&2
		failure_context_json="$(jq -nc \
			--arg failure_kind "curl-error" \
			--arg request_url "$request_url" \
			--arg request_host "$host_name" \
			--arg expected_class "$expected_class" \
			--argjson curl_exit_code "$curl_exit_code" \
			'{failure_kind: $failure_kind, request_url: $request_url, request_host: $request_host, expected_class: $expected_class, curl_exit_code: $curl_exit_code}')"
		capture_service_failure_bundle "$service_name" "$service_name" "metadata-validation-failed" "$failure_message" "$failure_context_json" "" "$response"
		return 1
	fi

	if ! printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
		failure_message="Received invalid metadata response for $service_name"
		echo "$failure_message" >&2
		failure_context_json="$(jq -nc \
			--arg failure_kind "invalid-json" \
			--arg request_url "$request_url" \
			--arg request_host "$host_name" \
			--arg expected_class "$expected_class" \
			'{failure_kind: $failure_kind, request_url: $request_url, request_host: $request_host, expected_class: $expected_class}')"
		capture_service_failure_bundle "$service_name" "$service_name" "metadata-validation-failed" "$failure_message" "$failure_context_json" "$response"
		return 1
	fi

	actual_service="$(printf '%s' "$response" | jq -r '.service')"
	actual_class="$(printf '%s' "$response" | jq -r '.class')"
	response_mode="$(printf '%s' "$response" | jq -r '.response_mode')"
	startup_delay="$(printf '%s' "$response" | jq -r '.startup_delay')"
	health_mode="$(printf '%s' "$response" | jq -r '.health_mode')"
	dependency_host="$(printf '%s' "$response" | jq -r '.dependency.host // ""')"
	failure_context_json="$(jq -nc \
		--arg failure_kind "validation" \
		--arg request_url "$request_url" \
		--arg request_host "$host_name" \
		--arg expected_class "$expected_class" \
		--arg actual_service "$actual_service" \
		--arg actual_class "$actual_class" \
		--arg response_mode "$response_mode" \
		--arg startup_delay "$startup_delay" \
		--arg health_mode "$health_mode" \
		--arg dependency_host "$dependency_host" \
		'{failure_kind: $failure_kind, request_url: $request_url, request_host: $request_host, expected_class: $expected_class, actual_service: $actual_service, actual_class: $actual_class, response_mode: $response_mode, startup_delay: $startup_delay, health_mode: $health_mode, dependency_host: $dependency_host}')"

	if [ "$actual_service" != "$service_name" ]; then
		failure_message="Expected service metadata for $service_name, got $actual_service"
		echo "$failure_message" >&2
		capture_service_failure_bundle "$service_name" "$service_name" "metadata-validation-failed" "$failure_message" "$failure_context_json" "$response"
		return 1
	fi

	if [ "$actual_class" != "$expected_class" ]; then
		failure_message="Expected workload class $expected_class for $service_name, got $actual_class"
		echo "$failure_message" >&2
		capture_service_failure_bundle "$service_name" "$service_name" "metadata-validation-failed" "$failure_message" "$failure_context_json" "$response"
		return 1
	fi

	case "$expected_class" in
		fast-api)
			if [ "$response_mode" != "json" ]; then
				failure_message="Expected fast-api workload $service_name to use json mode, got $response_mode"
				echo "$failure_message" >&2
				capture_service_failure_bundle "$service_name" "$service_name" "metadata-validation-failed" "$failure_message" "$failure_context_json" "$response"
				return 1
			fi
			;;
		slow-start)
			if [ "$startup_delay" = "0s" ]; then
				failure_message="Expected slow-start workload $service_name to advertise non-zero startup delay"
				echo "$failure_message" >&2
				capture_service_failure_bundle "$service_name" "$service_name" "metadata-validation-failed" "$failure_message" "$failure_context_json" "$response"
				return 1
			fi
			;;
		dependency-sensitive)
			if [ "$health_mode" != "dependency-gated" ] || [ -z "$dependency_host" ]; then
				failure_message="Expected dependency-sensitive workload $service_name to report dependency-gated health and dependency host"
				echo "$failure_message" >&2
				capture_service_failure_bundle "$service_name" "$service_name" "metadata-validation-failed" "$failure_message" "$failure_context_json" "$response"
				return 1
			fi
			;;
	esac

	echo "Validated metadata for $service_name ($expected_class)"
}

wake_workload_job() {
	job_name="$1"
	service_name="$2"
	workload_class="$3"
	wake_started_at="$(timestamp_utc)"
	wake_started_ms="$(timestamp_millis)"

	request_workload_metadata "$service_name" "$workload_class" &
	request_pid=$!

	"$ROOT_DIR"/e2e/scripts/wait-for-nomad-job.sh "$job_name" 1 "$nomad_wake_timeout"
	"$ROOT_DIR"/e2e/scripts/wait-for-consul-checks.sh "_nomad-check-" 1 "$startup_ready_timeout" "$service_name"
	wait "$request_pid"

	wake_finished_at="$(timestamp_utc)"
	wake_finished_ms="$(timestamp_millis)"
	LAST_WORKLOAD_WAKE_DURATION_MS=$((wake_finished_ms - wake_started_ms))
	record_event "workload-wake" "passed" "$(jq -nc \
		--arg job_name "$job_name" \
		--arg service_name "$service_name" \
		--arg workload_class "$workload_class" \
		--arg started_at "$wake_started_at" \
		--arg finished_at "$wake_finished_at" \
		--argjson duration_ms "$LAST_WORKLOAD_WAKE_DURATION_MS" \
		'{job_name: $job_name, service_name: $service_name, workload_class: $workload_class, started_at: $started_at, finished_at: $finished_at, duration_ms: $duration_ms}')"
	capture_state_snapshot "${job_name}-wake"
}

wake_all_workloads_concurrently() {
	request_pids=""
	wake_started_at="$(timestamp_utc)"
	wake_started_ms="$(timestamp_millis)"

	while IFS='|' read -r job_name service_name workload_class workload_ordinal job_spec_key; do
		[ -n "$job_name" ] || continue
		request_workload_metadata "$service_name" "$workload_class" &
		request_pids="${request_pids}${request_pids:+ }$!:${service_name}"
	done < "$WORKLOAD_MANIFEST_FILE"

	"$ROOT_DIR"/e2e/scripts/wait-for-nomad-running-count.sh "$WORKLOAD_PREFIX" "$JOB_COUNT" exact "$startup_ready_timeout" "$JOB_COUNT"

	for pid_and_service in $request_pids; do
		request_pid="${pid_and_service%%:*}"
		service_name="${pid_and_service#*:}"
		if ! wait "$request_pid"; then
			echo "Concurrent metadata request failed for $service_name" >&2
			exit 1
		fi
	done

	wait_for_all_workload_checks_healthy_concurrently

	wake_finished_at="$(timestamp_utc)"
	wake_finished_ms="$(timestamp_millis)"
	LAST_WAKE_ALL_DURATION_MS=$((wake_finished_ms - wake_started_ms))
	record_event "all-workloads-wake" "passed" "$(jq -nc \
		--arg started_at "$wake_started_at" \
		--arg finished_at "$wake_finished_at" \
		--argjson duration_ms "$LAST_WAKE_ALL_DURATION_MS" \
		--argjson expected_jobs "$JOB_COUNT" \
		'{started_at: $started_at, finished_at: $finished_at, duration_ms: $duration_ms, expected_jobs: $expected_jobs}')"
	capture_state_snapshot "all-workloads-wake"
}

wait_for_all_workload_checks_healthy_concurrently() {
	check_pids=""

	while IFS='|' read -r job_name service_name workload_class workload_ordinal job_spec_key; do
		[ -n "$job_name" ] || continue
		"$ROOT_DIR"/e2e/scripts/wait-for-consul-checks.sh "_nomad-check-" 1 "$startup_ready_timeout" "$service_name" &
		check_pids="${check_pids}${check_pids:+ }$!:${service_name}"
	done < "$WORKLOAD_MANIFEST_FILE"

	for pid_and_service in $check_pids; do
		check_pid="${pid_and_service%%:*}"
		service_name="${pid_and_service#*:}"
		if ! wait "$check_pid"; then
			echo "Consul readiness wait failed for $service_name" >&2
			exit 1
		fi
	done
}

validate_all_workloads_metadata_concurrently() {
	request_pids=""

	while IFS='|' read -r job_name service_name workload_class workload_ordinal job_spec_key; do
		[ -n "$job_name" ] || continue
		request_workload_metadata "$service_name" "$workload_class" &
		request_pids="${request_pids}${request_pids:+ }$!:${service_name}"
	done < "$WORKLOAD_MANIFEST_FILE"

	for pid_and_service in $request_pids; do
		request_pid="${pid_and_service%%:*}"
		service_name="${pid_and_service#*:}"
		if ! wait "$request_pid"; then
			echo "Post-wake metadata validation failed for $service_name" >&2
			exit 1
		fi
	done
}

write_k6_request_distribution_artifact() {
	source_results_file="$1"
	output_file="$2"
	expected_services="$3"

	if [ ! -f "$source_results_file" ]; then
		return 0
	fi

	jq -s --argjson expected_services "$expected_services" '
		def service_counts(metric_name):
			[
				.[]
				| select(.type == "Point" and .metric == metric_name and ((.data.tags.service // "") != ""))
				| .data.tags.service
			]
			| group_by(.)
			| map({service: .[0], count: length})
			| sort_by(.service);

		def failed_service_counts:
			[
				.[]
				| select(.type == "Point" and .metric == "http_req_failed" and ((.data.tags.service // "") != "") and .data.value == 1)
				| .data.tags.service
			]
			| group_by(.)
			| map({service: .[0], count: length})
			| sort_by(.service);

		{
			expected_services: $expected_services,
			services_hit: (service_counts("http_reqs") | length),
			requests_by_service: service_counts("http_reqs"),
			failed_requests_by_service: failed_service_counts
		}
	' "$source_results_file" > "$output_file"
}

run_k6_cycle() {
	label="$1"
	scenario_name="$2"
	target_mode="$3"
	service_name="${4:-}"
	label_slug="$(slugify "$label")"
	summary_file="$K6_ARTIFACTS_DIR/${label_slug}.summary.json"
	results_file="$K6_ARTIFACTS_DIR/${label_slug}.results.json"
	distribution_file="$K6_ARTIFACTS_DIR/${label_slug}.distribution.json"
	metadata_file="$K6_ARTIFACTS_DIR/${label_slug}.metadata.json"
	k6_started_at="$(timestamp_utc)"
	k6_started_ms="$(timestamp_millis)"

	printf "${CYAN}=== %s (%s) ===${NC}\n" "$label" "$scenario_name"
	record_event "k6-cycle-start" "running" "$(jq -nc \
		--arg cycle_label "$label" \
		--arg scenario "$scenario_name" \
		--arg target_mode "$target_mode" \
		--arg service_name "$service_name" \
		'{"label": $cycle_label, scenario: $scenario, target_mode: $target_mode, service_name: (if $service_name == "" then null else $service_name end)}')"

	export E2E_TRAFFIC_SCENARIO="$scenario_name"
	export E2E_K6_TARGET_MODE="$target_mode"
	export E2E_K6_RUN_LABEL="$label"
	export E2E_K6_SUMMARY_FILE="$summary_file"
	export E2E_K6_RESULTS_FILE="$results_file"
	if [ "$target_mode" = "fixed" ]; then
		export E2E_K6_SERVICE_NAME="$service_name"
	else
		unset E2E_K6_SERVICE_NAME
	fi

	"$ROOT_DIR"/e2e/scripts/run-k6-scenario.sh &
	k6_pid=$!

	if [ "$target_mode" = "fixed" ]; then
		"$ROOT_DIR"/e2e/scripts/wait-for-nomad-job.sh "$service_name" 1 "$nomad_wake_timeout"
		"$ROOT_DIR"/e2e/scripts/wait-for-consul-checks.sh "_nomad-check-" 1 "$startup_ready_timeout" "$service_name"
	elif [ "$scenario_name" = "coldstart" ] || [ "$target_mode" = "round-robin" ]; then
		"$ROOT_DIR"/e2e/scripts/wait-for-nomad-running-count.sh "$WORKLOAD_PREFIX" "$JOB_COUNT" exact "$startup_ready_timeout" "$JOB_COUNT"
		wait_for_all_workload_checks_healthy_concurrently
	else
		"$ROOT_DIR"/e2e/scripts/wait-for-nomad-running-count.sh "$WORKLOAD_PREFIX" 1 at-least "$nomad_wake_timeout" "$JOB_COUNT"
	fi

	wake_detected_at="$(timestamp_utc)"
	wake_detected_ms="$(timestamp_millis)"
	wake_duration_ms=$((wake_detected_ms - k6_started_ms))
	"$ROOT_DIR"/e2e/scripts/collect-redis-info.sh "${label}-post-wake" || true
	capture_state_snapshot "${label}-post-wake"

	if wait "$k6_pid"; then
		k6_exit_code=0
		k6_status="passed"
	else
		k6_exit_code=$?
		k6_status="failed"
	fi

	k6_finished_at="$(timestamp_utc)"
	k6_finished_ms="$(timestamp_millis)"
	k6_duration_ms=$((k6_finished_ms - k6_started_ms))
	write_k6_request_distribution_artifact "$results_file" "$distribution_file" "$JOB_COUNT"
	capture_state_snapshot "${label}-post-k6"

	jq -n \
		--arg cycle_label "$label" \
		--arg scenario "$scenario_name" \
		--arg target_mode "$target_mode" \
		--arg service_name "$service_name" \
		--arg status "$k6_status" \
		--arg started_at "$k6_started_at" \
		--arg wake_detected_at "$wake_detected_at" \
		--arg finished_at "$k6_finished_at" \
		--arg distribution_file "k6/${label_slug}.distribution.json" \
		--arg summary_file "k6/${label_slug}.summary.json" \
		--arg results_file "k6/${label_slug}.results.json" \
		--argjson wake_duration_ms "$wake_duration_ms" \
		--argjson duration_ms "$k6_duration_ms" \
		--argjson exit_code "$k6_exit_code" \
		'{
			"label": $cycle_label,
			scenario: $scenario,
			target_mode: $target_mode,
			service_name: (if $service_name == "" then null else $service_name end),
			status: $status,
			started_at: $started_at,
			wake_detected_at: $wake_detected_at,
			finished_at: $finished_at,
			distribution_file: $distribution_file,
			wake_duration_ms: $wake_duration_ms,
			duration_ms: $duration_ms,
			exit_code: $exit_code,
			summary_file: $summary_file,
			results_file: $results_file
		}' > "$metadata_file"

	LAST_K6_WAKE_DURATION_MS="$wake_duration_ms"
	LAST_K6_LABEL="$label"

	record_event "k6-cycle-complete" "$k6_status" "$(jq -nc \
		--arg cycle_label "$label" \
		--arg scenario "$scenario_name" \
		--arg target_mode "$target_mode" \
		--arg service_name "$service_name" \
		--arg status "$k6_status" \
		--arg metadata_file "k6/${label_slug}.metadata.json" \
		--arg summary_file "k6/${label_slug}.summary.json" \
		--arg results_file "k6/${label_slug}.results.json" \
		--argjson wake_duration_ms "$wake_duration_ms" \
		--argjson duration_ms "$k6_duration_ms" \
		--argjson exit_code "$k6_exit_code" \
		'{"label": $cycle_label, scenario: $scenario, target_mode: $target_mode, service_name: (if $service_name == "" then null else $service_name end), status: $status, metadata_file: $metadata_file, summary_file: $summary_file, results_file: $results_file, wake_duration_ms: $wake_duration_ms, duration_ms: $duration_ms, exit_code: $exit_code}')"

	if [ "$k6_exit_code" -ne 0 ]; then
		return "$k6_exit_code"
	fi
}

wait_for_all_workloads_scale_to_zero() {
	label="$1"
	if [ "$IDLE_SCALER_ISOLATION_ACTIVE" = "true" ]; then
		printf "${CYAN}=== Skip %s scale-to-zero (%s) ===${NC}\n" "$label" "$IDLE_SCALER_ISOLATION_MODE"
		LAST_SCALE_TO_ZERO_CONTEXT_JSON="$(jq -nc \
			--arg phase_label "$label" \
			--arg mode "$IDLE_SCALER_ISOLATION_MODE" \
			--arg reason "idle-scaler isolation mode is active; post-initial scale-to-zero validation is intentionally skipped" \
			'{label: $phase_label, status: "skipped", mode: $mode, reason: $reason}')"
		record_event "scale-to-zero" "skipped" "$LAST_SCALE_TO_ZERO_CONTEXT_JSON"
		capture_state_snapshot "${label}-scale-to-zero-skipped"
		return 0
	fi

	printf "${CYAN}=== Wait for %s scale-to-zero ===${NC}\n" "$label"
	scale_down_started_at="$(timestamp_utc)"
	scale_down_started_ms="$(timestamp_millis)"
	"$ROOT_DIR"/e2e/scripts/wait-for-nomad-running-count.sh "$WORKLOAD_PREFIX" 0 exact "$idle_wait_seconds" "$JOB_COUNT"
	nomad_zero_detected_ms="$(timestamp_millis)"
	wait_for_workload_consul_cleanup "$label"
	scale_down_finished_at="$(timestamp_utc)"
	scale_down_finished_ms="$(timestamp_millis)"
	nomad_scale_down_duration_ms=$((nomad_zero_detected_ms - scale_down_started_ms))
	workload_consul_cleanup_duration_ms=$((scale_down_finished_ms - nomad_zero_detected_ms))
	total_scale_down_duration_ms=$((scale_down_finished_ms - scale_down_started_ms))
	LAST_SCALE_TO_ZERO_CONTEXT_JSON="$(jq -nc \
		--arg phase_label "$label" \
		--arg started_at "$scale_down_started_at" \
		--arg finished_at "$scale_down_finished_at" \
		--argjson nomad_scale_down_duration_ms "$nomad_scale_down_duration_ms" \
		--argjson workload_consul_cleanup_duration_ms "$workload_consul_cleanup_duration_ms" \
		--argjson total_duration_ms "$total_scale_down_duration_ms" \
		'{label: $phase_label, status: "passed", started_at: $started_at, finished_at: $finished_at, nomad_scale_down_duration_ms: $nomad_scale_down_duration_ms, workload_consul_cleanup_duration_ms: $workload_consul_cleanup_duration_ms, total_duration_ms: $total_duration_ms}')"
	record_event "scale-to-zero" "passed" "$LAST_SCALE_TO_ZERO_CONTEXT_JSON"
	capture_state_snapshot "${label}-scale-to-zero"
	wait_for_consul_cleanup "$label"
	LAST_SCALE_TO_ZERO_CONTEXT_JSON="$(printf '%s' "$LAST_SCALE_TO_ZERO_CONTEXT_JSON" | jq -c \
		--argjson baseline_consul_cleanup_duration_ms "$CONSUL_CLEANUP_LAST_DURATION_MS" \
		'. + {baseline_consul_cleanup_duration_ms: $baseline_consul_cleanup_duration_ms}')"
}

assert_job_spec_present() {
	job_name="$1"
	spec_key="$2"

	case "$STORE_TYPE" in
		redis)
			redis_addr="${E2E_REDIS_ADDR:-redis:6379}"
			redis_host="${redis_addr%:*}"
			redis_port="${redis_addr#*:}"
			if [ -n "${E2E_REDIS_PASSWORD:-}" ]; then
				spec_payload="$(redis-cli -h "$redis_host" -p "$redis_port" -a "$E2E_REDIS_PASSWORD" --raw GET "$spec_key" 2>/dev/null || true)"
			else
				spec_payload="$(redis-cli -h "$redis_host" -p "$redis_port" --raw GET "$spec_key" 2>/dev/null || true)"
			fi
			;;
		consul)
			spec_payload="$(consul_get "/v1/kv/${spec_key}?raw" 2>/dev/null || true)"
			;;
		*)
			echo "Unsupported E2E_STORE_TYPE for job spec validation: $STORE_TYPE" >&2
			exit 1
			;;
	esac

	if [ -z "$spec_payload" ]; then
		echo "Missing stored job spec for $job_name at $spec_key" >&2
		exit 1
	fi

	if ! printf '%s' "$spec_payload" | jq -e --arg job_name "$job_name" '((.ID // .Job.ID) == $job_name) and ((((.Stop // .Job.Stop) // false) == false))' >/dev/null; then
		echo "Stored job spec for $job_name at $spec_key did not validate" >&2
		exit 1
	fi

	echo "Validated stored job spec for $job_name at $spec_key"
}

purge_nomad_job() {
	job_name="$1"
	nomad_delete "/v1/job/$job_name?purge=true"
	"$ROOT_DIR"/e2e/scripts/wait-for-nomad-job.sh "$job_name" 0 "$startup_ready_timeout"
}

wait_for_nomad_job_inactive() {
	job_name="$1"
	start="$(date +%s)"

	while true; do
		status="$(nomad_job_status "$job_name")"
		case "$status" in
			not-found|dead|stopped)
				echo "Job $job_name is inactive (${status})"
				return 0
				;;
		esac

		now="$(date +%s)"
		if [ $((now - start)) -ge "$startup_ready_timeout" ]; then
			echo "Timed out waiting for $job_name to become inactive (last status=${status})" >&2
			exit 1
		fi

		sleep 2
	done
}

run_mixed_traffic_scenario() {
	printf "${CYAN}=== Scenario: mixed-traffic ===${NC}\n"
	run_k6_cycle "mixed-traffic-cold-start" "coldstart" "round-robin"
	mixed_traffic_cold_start_k6_label="$LAST_K6_LABEL"
	mixed_traffic_cold_start_duration_ms="$LAST_K6_WAKE_DURATION_MS"
	validate_all_workloads_metadata_concurrently
	"$ROOT_DIR"/e2e/scripts/collect-redis-info.sh "mixed-traffic-matrix-wake" || true
	capture_state_snapshot "mixed-traffic-matrix-wake"

	cycle=1
	while [ "$cycle" -le "$SOAK_CYCLES" ]; do
		traffic_shape="$(traffic_shape_for_cycle "$cycle")"
		if [ "$K6_TARGET_MODE" = "fixed" ]; then
			fixed_service_name="$(fixed_service_name_for_cycle "$cycle")"
		else
			fixed_service_name=""
		fi
		if [ "$K6_TARGET_MODE" = "round-robin" ] && [ "$cycle" -gt 1 ]; then
			wake_all_workloads_concurrently
			validate_all_workloads_metadata_concurrently
			"$ROOT_DIR"/e2e/scripts/collect-redis-info.sh "mixed-traffic-cycle-${cycle}-matrix-wake" || true
			capture_state_snapshot "mixed-traffic-cycle-${cycle}-matrix-wake"
		fi
		run_k6_cycle "mixed-traffic-cycle-${cycle}" "$traffic_shape" "$K6_TARGET_MODE" "$fixed_service_name"
		cycle=$((cycle + 1))
	done

	wait_for_all_workloads_scale_to_zero "mixed-traffic"
	SCENARIO_RESULT_CONTEXT_JSON="$(jq -nc \
		--arg traffic_shape "$TRAFFIC_SHAPE_LIST" \
		--arg target_mode "$K6_TARGET_MODE" \
		--arg cold_start_k6_label "$mixed_traffic_cold_start_k6_label" \
		--argjson soak_cycles "$SOAK_CYCLES" \
		--argjson initial_wake_duration_ms "$mixed_traffic_cold_start_duration_ms" \
		'{traffic_shapes: ($traffic_shape | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(length > 0))), target_mode: $target_mode, soak_cycles: $soak_cycles, initial_wake_duration_ms: $initial_wake_duration_ms, cold_start_k6_label: (if $cold_start_k6_label == "" then null else $cold_start_k6_label end)}')"
}

run_dead_job_revival_scenario() {
	printf "${CYAN}=== Scenario: dead-job-revival ===${NC}\n"
	target_entry="$(select_revival_target_entry)"
	IFS='|' read -r job_name service_name workload_class workload_ordinal job_spec_key <<EOF
$target_entry
EOF

	assert_job_spec_present "$job_name" "$job_spec_key"
	printf "Purging %s to validate stored job spec revival\n" "$job_name"
	purge_nomad_job "$job_name"
	wait_for_nomad_job_inactive "$job_name"
	run_k6_cycle "dead-job-revival-cold-start" "coldstart" "fixed" "$service_name"
	request_workload_metadata "$service_name" "$workload_class"
	"$ROOT_DIR"/e2e/scripts/collect-redis-info.sh "dead-job-revival-post-wake" || true
	capture_state_snapshot "dead-job-revival-post-wake"
	wait_for_all_workloads_scale_to_zero "dead-job-revival"
	SCENARIO_RESULT_CONTEXT_JSON="$(jq -nc \
		--arg job_name "$job_name" \
		--arg service_name "$service_name" \
		--arg workload_class "$workload_class" \
		--arg job_spec_key "$job_spec_key" \
		--arg cold_start_k6_label "$LAST_K6_LABEL" \
		--argjson recovery_duration_ms "$LAST_K6_WAKE_DURATION_MS" \
		'{job_name: $job_name, service_name: $service_name, workload_class: $workload_class, job_spec_key: $job_spec_key, recovery_duration_ms: $recovery_duration_ms, cold_start_k6_label: (if $cold_start_k6_label == "" then null else $cold_start_k6_label end)}')"
}

run_idle_scaler_restart_scenario() {
	printf "${CYAN}=== Scenario: idle-scaler-restart ===${NC}\n"
	if [ "$IDLE_SCALER_PLACEMENT" != "nomad-system-job" ]; then
		echo "idle-scaler-restart requires E2E_TARGET_IDLE_SCALER_PLACEMENT=nomad-system-job" >&2
		exit 1
	fi

	purge_nomad_job "idle-scaler-e2e"
	wait_for_nomad_job_inactive "idle-scaler-e2e"
	submit_nomad_idle_scaler

	target_entry="$(select_revival_target_entry)"
	IFS='|' read -r job_name service_name workload_class workload_ordinal job_spec_key <<EOF
$target_entry
EOF

	run_k6_cycle "idle-scaler-restart-cold-start" "coldstart" "fixed" "$service_name"
	request_workload_metadata "$service_name" "$workload_class"
	"$ROOT_DIR"/e2e/scripts/collect-redis-info.sh "idle-scaler-restart-post-wake" || true
	capture_state_snapshot "idle-scaler-restart-post-wake"
	wait_for_all_workloads_scale_to_zero "idle-scaler-restart"
	SCENARIO_RESULT_CONTEXT_JSON="$(jq -nc \
		--arg job_name "$job_name" \
		--arg service_name "$service_name" \
		--arg workload_class "$workload_class" \
		--arg restart_job_name "idle-scaler-e2e" \
		--arg cold_start_k6_label "$LAST_K6_LABEL" \
		--argjson recovery_duration_ms "$LAST_K6_WAKE_DURATION_MS" \
		'{job_name: $job_name, service_name: $service_name, workload_class: $workload_class, restart_job_name: $restart_job_name, recovery_duration_ms: $recovery_duration_ms, cold_start_k6_label: (if $cold_start_k6_label == "" then null else $cold_start_k6_label end)}')"
}

run_cleanup_consistency_scenario() {
	printf "${CYAN}=== Scenario: cleanup-consistency ===${NC}\n"
	wait_for_consul_cleanup "cleanup-consistency"
	capture_state_snapshot "cleanup-consistency"
	SCENARIO_RESULT_CONTEXT_JSON="$(jq -nc --argjson cleanup_duration_ms "$CONSUL_CLEANUP_LAST_DURATION_MS" '{cleanup_duration_ms: $cleanup_duration_ms}')"
}

run_scenario_impl() {
	scenario_name="$1"
	case "$scenario_name" in
		mixed-traffic)
			run_mixed_traffic_scenario
			;;
		dead-job-revival)
			run_dead_job_revival_scenario
			;;
		idle-scaler-restart|restart-recovery)
			run_idle_scaler_restart_scenario
			;;
		cleanup-consistency|consistency)
			run_cleanup_consistency_scenario
			;;
		*)
			echo "Unknown E2E scenario: $scenario_name" >&2
			exit 1
			;;
	esac
}

run_scenario() {
	scenario_id="$1"
	scenario_slug="$(slugify "$scenario_id")"
	scenario_file="$SCENARIO_ARTIFACTS_DIR/${scenario_slug}.json"
	scenario_started_at="$(timestamp_utc)"
	scenario_started_ms="$(timestamp_millis)"
	ACTIVE_SCENARIO="$scenario_id"
	SCENARIO_RESULT_CONTEXT_JSON='{}'
	LAST_SCALE_TO_ZERO_CONTEXT_JSON='null'

	record_event "scenario-start" "running" "$(jq -nc --arg scenario "$scenario_id" '{scenario: $scenario}')"
	capture_state_snapshot "${scenario_id}-start"

	if run_scenario_impl "$scenario_id"; then
		scenario_status="passed"
	else
		scenario_status="failed"
	fi

	scenario_finished_at="$(timestamp_utc)"
	scenario_finished_ms="$(timestamp_millis)"
	scenario_duration_ms=$((scenario_finished_ms - scenario_started_ms))

	jq -n \
		--arg scenario "$scenario_id" \
		--arg status "$scenario_status" \
		--arg started_at "$scenario_started_at" \
		--arg finished_at "$scenario_finished_at" \
		--argjson duration_ms "$scenario_duration_ms" \
		--argjson scenario_context "$SCENARIO_RESULT_CONTEXT_JSON" \
		--arg idle_scaler_isolation_mode "$IDLE_SCALER_ISOLATION_MODE" \
		--argjson idle_scaler_isolation_active "$IDLE_SCALER_ISOLATION_ACTIVE" \
		--argjson scale_to_zero_context "$LAST_SCALE_TO_ZERO_CONTEXT_JSON" \
		'{
			scenario: $scenario,
			status: $status,
			started_at: $started_at,
			finished_at: $finished_at,
			duration_ms: $duration_ms
		}
		+ $scenario_context
		+ {
			idle_scaler_isolation_mode: $idle_scaler_isolation_mode,
			idle_scaler_isolation_active: $idle_scaler_isolation_active
		}
		+ (if $scale_to_zero_context == null then {} else {post_initial_scale_to_zero: $scale_to_zero_context} end)' > "$scenario_file"

	record_event "scenario-complete" "$scenario_status" "$(jq -nc --arg scenario "$scenario_id" --arg result_file "scenarios/${scenario_slug}.json" --argjson duration_ms "$scenario_duration_ms" '{scenario: $scenario, result_file: $result_file, duration_ms: $duration_ms}')"
	capture_state_snapshot "${scenario_id}-${scenario_status}"
	ACTIVE_SCENARIO=""

	if [ "$scenario_status" != "passed" ]; then
		return 1
	fi
}

execute_scenarios() {
	for raw_scenario in $(printf '%s' "$SCENARIO_SET" | tr ',' ' '); do
		scenario_name="$(printf '%s' "$raw_scenario" | tr -d '[:space:]')"
		[ -n "$scenario_name" ] || continue
		run_scenario "$scenario_name"
	done
}

printf "${CYAN}=== E2E configuration ===${NC}\n"
printf "  E2E_PROFILE=%s\n" "${E2E_PROFILE:-unset}"
printf "  E2E_PROFILE_DESCRIPTION=%s\n" "${E2E_PROFILE_DESCRIPTION:-unset}"
printf "  E2E_AUTOMATION_JOB_NAME=%s\n" "${E2E_AUTOMATION_JOB_NAME:-unset}"
printf "  E2E_AUTOMATION_SMOKE_JOB=%s\n" "${E2E_AUTOMATION_SMOKE_JOB:-unset}"
printf "  E2E_AUTOMATION_CERTIFICATION_JOB=%s\n" "${E2E_AUTOMATION_CERTIFICATION_JOB:-unset}"
printf "  E2E_TARGET_NOMAD_SERVERS=%s\n" "${E2E_TARGET_NOMAD_SERVERS:-unset}"
printf "  E2E_TARGET_NOMAD_CLIENTS=%s\n" "${E2E_TARGET_NOMAD_CLIENTS:-unset}"
printf "  E2E_TARGET_CONSUL_SERVERS=%s\n" "${E2E_TARGET_CONSUL_SERVERS:-unset}"
printf "  E2E_TARGET_TRAEFIK_REPLICAS=%s\n" "${E2E_TARGET_TRAEFIK_REPLICAS:-unset}"
printf "  E2E_TARGET_REDIS_NODES=%s\n" "${E2E_TARGET_REDIS_NODES:-unset}"
printf "  E2E_TARGET_IDLE_SCALER_PLACEMENT=%s\n" "${E2E_TARGET_IDLE_SCALER_PLACEMENT:-unset}"
printf "  E2E_TARGET_IDLE_SCALER_ISOLATION_MODE=%s\n" "$IDLE_SCALER_ISOLATION_MODE"
printf "  E2E_IDLE_SCALER_EXPECTED_RUNNING=%s\n" "$IDLE_SCALER_EXPECTED_RUNNING"
printf "  E2E_WORKLOAD_MIX_LABELS=%s\n" "${E2E_WORKLOAD_MIX_LABELS:-unset}"
printf "  E2E_WORKLOAD_FAST_API_COUNT=%s\n" "${E2E_WORKLOAD_FAST_API_COUNT:-unset}"
printf "  E2E_WORKLOAD_SLOW_START_COUNT=%s\n" "${E2E_WORKLOAD_SLOW_START_COUNT:-unset}"
printf "  E2E_WORKLOAD_DEPENDENCY_SENSITIVE_COUNT=%s\n" "${E2E_WORKLOAD_DEPENDENCY_SENSITIVE_COUNT:-unset}"
printf "  E2E_TRAFFIC_SHAPE=%s\n" "${E2E_TRAFFIC_SHAPE:-unset}"
printf "  E2E_JOB_COUNT=%s\n" "$JOB_COUNT"
printf "  E2E_IDLE_TIMEOUT=%s\n" "$IDLE_TIMEOUT"
printf "  E2E_IDLE_CHECK_INTERVAL=%s\n" "$IDLE_CHECK_INTERVAL"
printf "  E2E_MIN_SCALE_DOWN_AGE=%s\n" "$MIN_SCALE_DOWN_AGE"
printf "  E2E_SOAK_CYCLES=%s\n" "$SOAK_CYCLES"
printf "  E2E_SCENARIO_SET_REQUESTED=%s\n" "$REQUESTED_SCENARIO_SET"
printf "  E2E_SCENARIO_SET=%s\n" "$SCENARIO_SET"
if [ -n "$EXCLUDED_SCENARIO_SET" ]; then
	printf "  E2E_SCENARIO_SET_EXCLUDED=%s\n" "$EXCLUDED_SCENARIO_SET"
fi
printf "  E2E_POST_INITIAL_SCALE_TO_ZERO_EXPECTED=%s\n" "$POST_INITIAL_SCALE_TO_ZERO_EXPECTED"
printf "  E2E_REQUEST_TIMEOUT=%s\n" "$REQUEST_TIMEOUT"
printf "  E2E_TRAFFIC_SCENARIO=%s\n" "$TRAFFIC_SCENARIO"
printf "  E2E_TRAFFIC_SHAPE=%s\n" "$TRAFFIC_SHAPE_LIST"
printf "  E2E_K6_TARGET_MODE=%s\n" "$K6_TARGET_MODE"
printf "  E2E_STORE_TYPE=%s\n" "$STORE_TYPE"
printf "  E2E_STARTUP_READY_TIMEOUT=%s\n" "$startup_ready_timeout"
printf "  E2E_NOMAD_WAKE_TIMEOUT=%s\n" "$nomad_wake_timeout"
printf "  E2E_CONSUL_CHECKS_TIMEOUT=%s\n" "$consul_checks_timeout"
printf "  E2E_CONSUL_CLEANUP_TIMEOUT=%s\n" "$consul_cleanup_timeout"
printf "  E2E_GENERATED_DIR=%s\n" "$GENERATED_DIR"
printf "  E2E_RUN_ID=%s\n" "$RUN_ID"
printf "  E2E_ARTIFACTS_DIR=%s\n" "$ARTIFACTS_DIR"
printf "  E2E_GATE_TRAFFIC_SUCCESS_RATE=%s\n" "${E2E_GATE_TRAFFIC_SUCCESS_RATE:-unset}"
printf "  E2E_GATE_WAKE_P95_MS=%s\n" "${E2E_GATE_WAKE_P95_MS:-unset}"
printf "  E2E_GATE_WAKE_P99_MS=%s\n" "${E2E_GATE_WAKE_P99_MS:-unset}"
printf "  E2E_GATE_SCALE_TO_ZERO_MAX_SECONDS=%s\n" "${E2E_GATE_SCALE_TO_ZERO_MAX_SECONDS:-unset}"
printf "  E2E_GATE_DEPENDENCY_READY_MAX_SECONDS=%s\n" "${E2E_GATE_DEPENDENCY_READY_MAX_SECONDS:-unset}"

mkdir -p \
	"$GENERATED_DIR" \
	"$GENERATED_JOBS_DIR" \
	"$ARTIFACTS_DIR" \
	"$K6_ARTIFACTS_DIR" \
	"$STATE_ARTIFACTS_DIR" \
	"$SCENARIO_ARTIFACTS_DIR" \
	"$WORKLOAD_ARTIFACTS_DIR" \
	"$CLEANUP_ARTIFACTS_DIR" \
	"$FAILURE_ARTIFACTS_DIR"

write_run_metadata
write_run_status "running" 0 "" 0
ARTIFACTS_READY=1
trap on_exit EXIT
record_event "run-start" "running" "$(jq -nc \
	--arg run_id "$RUN_ID" \
	--arg profile "${E2E_PROFILE:-}" \
	--arg idle_scaler_placement "$IDLE_SCALER_PLACEMENT" \
	--arg idle_scaler_isolation_mode "$IDLE_SCALER_ISOLATION_MODE" \
	--arg requested_scenario_set "$REQUESTED_SCENARIO_SET" \
	--arg effective_scenario_set "$SCENARIO_SET" \
	--arg excluded_scenario_set "$EXCLUDED_SCENARIO_SET" \
	--argjson post_initial_scale_to_zero_expected "$POST_INITIAL_SCALE_TO_ZERO_EXPECTED" \
	'{
		run_id: $run_id,
		profile: $profile,
		idle_scaler_placement: $idle_scaler_placement,
		idle_scaler_isolation_mode: $idle_scaler_isolation_mode,
		requested_scenario_set: $requested_scenario_set,
		effective_scenario_set: $effective_scenario_set,
		excluded_scenario_set: (if $excluded_scenario_set == "" then null else $excluded_scenario_set end),
		post_initial_scale_to_zero_expected: $post_initial_scale_to_zero_expected
	}')"

"$ROOT_DIR"/e2e/scripts/wait-for-http.sh "$CONSUL_ADDR/v1/status/leader" consul
"$ROOT_DIR"/e2e/scripts/wait-for-http.sh "$NOMAD_ADDR/v1/status/leader" nomad
"$ROOT_DIR"/e2e/scripts/wait-for-http.sh "$TRAEFIK_URL/ping" traefik
"$ROOT_DIR"/e2e/scripts/wait-for-nomad-ready-nodes.sh "$TARGET_NOMAD_CLIENTS" "$startup_ready_timeout"
"$ROOT_DIR"/e2e/scripts/wait-for-consul-checks.sh "_nomad-check-" 1 "$consul_checks_timeout"
prepare_idle_scaler
capture_consul_baseline
capture_state_snapshot "control-plane-ready"

printf "${CYAN}=== Generate Nomad jobs ===${NC}\n"
"$ROOT_DIR"/e2e/scripts/render-workload-jobs.sh
require_workload_manifest
persist_generated_artifacts

printf "${CYAN}=== Submit workload jobs ===${NC}\n"
for job_file in "$GENERATED_JOBS_DIR"/*.nomad; do
	submit_job "$job_file"
done

"$ROOT_DIR"/e2e/scripts/wait-for-nomad-running-count.sh "$WORKLOAD_PREFIX" "$JOB_COUNT" exact "$startup_ready_timeout" "$JOB_COUNT"
capture_state_snapshot "workloads-submitted"

printf "${CYAN}=== Initial Redis snapshot ===${NC}\n"
"$ROOT_DIR"/e2e/scripts/collect-redis-info.sh initial || true
capture_state_snapshot "initial-workloads-running"

printf "${CYAN}=== Wait for initial scale-to-zero ===${NC}\n"
"$ROOT_DIR"/e2e/scripts/wait-for-nomad-running-count.sh "$WORKLOAD_PREFIX" 0 exact "$idle_wait_seconds" "$JOB_COUNT"
wait_for_consul_cleanup "initial scale-to-zero"
capture_state_snapshot "initial-scale-to-zero"
activate_idle_scaler_isolation_mode

execute_scenarios

printf "${CYAN}=== E2E bootstrap ===${NC}\n"
printf "Rendered jobs were submitted to Nomad, idle-scaler placement=%s was prepared, isolation mode=%s, and scenario set %s completed.\n" "$IDLE_SCALER_PLACEMENT" "$IDLE_SCALER_ISOLATION_MODE" "$SCENARIO_SET"
if [ -n "$EXCLUDED_SCENARIO_SET" ]; then
	printf "Isolation mode excluded scaler-control scenarios from %s (excluded: %s).\n" "$REQUESTED_SCENARIO_SET" "$EXCLUDED_SCENARIO_SET"
fi
if [ "$IDLE_SCALER_ISOLATION_ACTIVE" = "true" ]; then
	printf "Idle-scaler isolation became active after the initial scale-to-zero checkpoint; later scaler-dependent scale-to-zero checks were skipped intentionally.\n"
fi
printf "The e2e harness now validates matrix traffic, recovery flows, and Consul cleanup consistency across repeated wake -> healthy -> idle -> zero transitions.\n"

printf "${GREEN}E2E scenario suite completed; release-gate evaluation follows from %s${NC}\n" "$ARTIFACTS_DIR"
