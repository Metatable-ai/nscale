#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Evaluate E2E release gates from a generated artifact set.
# Missing core evidence is reported as an inconclusive no-go (exit 2), which
# keeps artifact gaps distinguishable from proven gate failures (exit 1).

set -eu

timestamp_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
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

canonical_phase_label() {
	case "$1" in
		restart-recovery)
			printf '%s' "idle-scaler-restart"
			;;
		consistency)
			printf '%s' "cleanup-consistency"
			;;
		*)
			printf '%s' "$1"
			;;
	esac
}

scenario_has_scale_phase() {
	case "$1" in
		mixed-traffic|dead-job-revival|idle-scaler-restart|restart-recovery)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

scenario_has_recovery_gate() {
	case "$1" in
		dead-job-revival|idle-scaler-restart|restart-recovery)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

json_array_from_lines() {
	if [ -n "${1:-}" ]; then
		printf '%s\n' "$1" | jq -R -s 'split("\n") | map(select(length > 0))'
	else
		printf '[]'
	fi
}

json_array_from_records() {
	if [ -n "${1:-}" ]; then
		printf '%s\n' "$1" | jq -s '.'
	else
		printf '[]'
	fi
}

emit_summary() {
	summary_text="$(jq -r '
		"RELEASE GATES: " + (if .decision == "go" then "GO" else "NO-GO" end) + " (" + .status + ")",
		"run_id=" + ((.run_id // "unknown") | tostring) + " profile=" + (((.profile.name // "unknown")) | tostring),
		"idle_scaler_placement=" + ((.idle_scaler.placement // "unknown") | tostring) + " isolation_mode=" + ((.idle_scaler.isolation_mode // "disabled") | tostring) + " isolation_active=" + ((.idle_scaler.isolation_active // false) | tostring),
		"scenario_plan=requested=" + ((.scenario_plan.requested // []) | join(",")) + " effective=" + ((.scenario_plan.effective // []) | join(",")) + (if ((.scenario_plan.excluded // []) | length) == 0 then "" else " excluded=" + ((.scenario_plan.excluded // []) | join(",")) end),
		"artifacts_dir=" + .artifacts_dir,
		"requested_scenarios=" + (.summary.requested_scenarios | tostring)
			+ " expected_k6_cycles=" + (.summary.expected_k6_cycles | tostring)
			+ " cleanup_checks=" + (.summary.cleanup_checks | tostring)
			+ " state_snapshots=" + (.summary.state_snapshots | tostring),
		(.gates[] | "- " + .id + ": " + (.status | ascii_upcase) + " — " + .summary),
		"Structured output: " + .output.release_gates_file,
		"Summary file: " + .output.release_gates_summary_file
	' "$release_gates_file")"
	printf '%s\n' "$summary_text" | tee "$release_gates_summary_file"
}

write_inconclusive_result() {
	missing_json="$1"

	jq -n \
		--arg evaluated_at "$evaluated_at" \
		--arg artifacts_dir "$artifacts_dir" \
		--arg release_gates_file "$release_gates_file" \
		--arg release_gates_summary_file "$release_gates_summary_file" \
		--argjson missing_files "$missing_json" \
		'{
			run_id: null,
			evaluated_at: $evaluated_at,
			artifacts_dir: $artifacts_dir,
			profile: {},
			decision: "no-go",
			status: "inconclusive",
			exit_code: 2,
			thresholds: {
				traffic_success_rate: null,
				wake_p95_ms: null,
				wake_p99_ms: null,
				scale_to_zero_max_seconds: null,
				dependency_ready_max_seconds: null
			},
			summary: {
				requested_scenarios: 0,
				expected_k6_cycles: 0,
				expected_scale_cycles: 0,
				cleanup_checks: 0,
				state_snapshots: 0,
				event_count: 0,
				worst_traffic_success_rate: null,
				worst_latency_p95_ms: null,
				worst_latency_p99_ms: null,
				worst_scale_to_zero_duration_ms: null,
				worst_recovery_duration_ms: null
			},
			output: {
				release_gates_file: $release_gates_file,
				release_gates_summary_file: $release_gates_summary_file
			},
			events: {
				present: false,
				total: 0,
				counts: {}
			},
			artifacts: {
				run_metadata_file: "run-metadata.json",
				run_status_file: "run-status.json",
				events_file: null,
				scenario_results: [],
				k6_cycles: [],
				cleanup_checks: [],
				scale_to_zero_cycles: [],
				state_snapshots: {
					count: 0,
					labels: [],
					items: []
				}
			},
			gates: [
				{
					id: "artifact-presence",
					required: true,
					status: "inconclusive",
					summary: ("Missing required top-level artifacts: " + ($missing_files | join(", "))),
					details: {
						missing_files: $missing_files
					}
				}
			]
		}' > "$release_gates_file"

	emit_summary
	exit 2
}

artifacts_dir="${1:-${E2E_ARTIFACTS_DIR:-}}"
if [ -z "$artifacts_dir" ]; then
	echo "Usage: $0 <artifacts-dir>" >&2
	exit 64
fi

case "$artifacts_dir" in
	/*)
		;;
	*)
		artifacts_dir="$PWD/$artifacts_dir"
		;;
esac

run_metadata_file="$artifacts_dir/run-metadata.json"
run_status_file="$artifacts_dir/run-status.json"
events_file="$artifacts_dir/events.jsonl"
release_gates_file="${E2E_RELEASE_GATES_FILE:-$artifacts_dir/release-gates.json}"
release_gates_summary_file="${E2E_RELEASE_GATES_SUMMARY_FILE:-$artifacts_dir/release-gates-summary.txt}"
evaluated_at="$(timestamp_utc)"

mkdir -p "$(dirname "$release_gates_file")" "$(dirname "$release_gates_summary_file")"

missing_top_level_files=""
[ -f "$run_metadata_file" ] || missing_top_level_files="${missing_top_level_files}${missing_top_level_files:+
}run-metadata.json"
[ -f "$run_status_file" ] || missing_top_level_files="${missing_top_level_files}${missing_top_level_files:+
}run-status.json"
if [ -n "$missing_top_level_files" ]; then
	write_inconclusive_result "$(json_array_from_lines "$missing_top_level_files")"
fi

profile_name="$(jq -r '.profile.name // ""' "$run_metadata_file")"
run_id="$(jq -r '.run_id // ""' "$run_metadata_file")"
soak_cycles="$(jq -r '.traffic.soak_cycles // 0' "$run_metadata_file")"
requested_scenarios="$(jq -r '.scenarios[]?' "$run_metadata_file")"
idle_scaler_placement="$(jq -r '.idle_scaler.placement // .topology.idle_scaler_placement // "unknown"' "$run_metadata_file")"
idle_scaler_isolation_mode="$(jq -r '.idle_scaler.isolation_mode // "disabled"' "$run_metadata_file")"
idle_scaler_isolation_active="$(jq -r 'if ((.idle_scaler | type) == "object" and (.idle_scaler | has("isolation_active"))) then .idle_scaler.isolation_active else false end' "$run_metadata_file")"
post_initial_scale_to_zero_expected="$(jq -r 'if ((.idle_scaler | type) == "object" and (.idle_scaler | has("post_initial_scale_to_zero_expected"))) then .idle_scaler.post_initial_scale_to_zero_expected else true end' "$run_metadata_file")"

scenario_records=""
expected_k6_labels=""
expected_scale_labels=""
expected_cleanup_labels="initial scale-to-zero"

while IFS= read -r scenario_id; do
	[ -n "$scenario_id" ] || continue

	phase_label="$(canonical_phase_label "$scenario_id")"
	scenario_slug="$(slugify "$scenario_id")"
	scenario_file="$artifacts_dir/scenarios/$scenario_slug.json"

	if [ -f "$scenario_file" ]; then
		record="$(jq -c \
			--arg scenario_id "$scenario_id" \
			--arg phase_label "$phase_label" \
			--arg file "scenarios/$scenario_slug.json" \
			'. + {scenario_id: $scenario_id, phase_label: $phase_label, file: $file, exists: true}' \
			"$scenario_file")"
	else
		record="$(jq -nc \
			--arg scenario_id "$scenario_id" \
			--arg phase_label "$phase_label" \
			--arg file "scenarios/$scenario_slug.json" \
			'{
				scenario_id: $scenario_id,
				scenario: $scenario_id,
				phase_label: $phase_label,
				file: $file,
				exists: false,
				status: "missing"
			}')"
	fi
	scenario_records="${scenario_records}${scenario_records:+
}$record"

	case "$phase_label" in
		mixed-traffic)
			expected_k6_labels="${expected_k6_labels}${expected_k6_labels:+
}mixed-traffic-cold-start"
		cycle=1
		while [ "$cycle" -le "$soak_cycles" ]; do
			k6_label="mixed-traffic-cycle-$cycle"
			expected_k6_labels="${expected_k6_labels}${expected_k6_labels:+
}$k6_label"
			cycle=$((cycle + 1))
		done
			;;
		dead-job-revival|idle-scaler-restart)
			k6_label="${phase_label}-cold-start"
			expected_k6_labels="${expected_k6_labels}${expected_k6_labels:+
}$k6_label"
			;;
	esac

	if scenario_has_scale_phase "$scenario_id" && [ "$post_initial_scale_to_zero_expected" = "true" ]; then
		expected_scale_labels="${expected_scale_labels}${expected_scale_labels:+
}$phase_label"
		expected_cleanup_labels="${expected_cleanup_labels}${expected_cleanup_labels:+
}$phase_label"
	elif [ "$phase_label" = "cleanup-consistency" ] && [ "$post_initial_scale_to_zero_expected" = "true" ]; then
		expected_cleanup_labels="${expected_cleanup_labels}${expected_cleanup_labels:+
}$phase_label"
	fi
done <<EOF
$requested_scenarios
EOF

expected_scale_labels="$(printf '%s\n' "$expected_scale_labels" | sed '/^$/d' | sort -u)"
expected_cleanup_labels="$(printf '%s\n' "$expected_cleanup_labels" | sed '/^$/d' | sort -u)"

k6_cycle_records=""
while IFS= read -r k6_label; do
	[ -n "$k6_label" ] || continue
	k6_slug="$(slugify "$k6_label")"
	metadata_file="$artifacts_dir/k6/$k6_slug.metadata.json"
	summary_file="$artifacts_dir/k6/$k6_slug.summary.json"

	if [ ! -f "$metadata_file" ]; then
		record="$(jq -nc \
			--arg missing_label "$k6_label" \
			--arg file "k6/$k6_slug.metadata.json" \
			--arg summary_file "k6/$k6_slug.summary.json" \
			'{
				"label": $missing_label,
				file: $file,
				summary_file: $summary_file,
				exists: false,
				summary_exists: false,
				status: "missing"
			}')"
	elif [ -f "$summary_file" ]; then
		record="$(jq -c \
			--arg file "k6/$k6_slug.metadata.json" \
			--arg summary_file_rel "k6/$k6_slug.summary.json" \
			--slurpfile summary "$summary_file" \
			'($summary[0] // {}) as $s
			| (.expected_iterations? // null) as $expected_iterations
			| (($s.metrics.iterations.count? // null)) as $completed_iterations
			| . + {
				file: $file,
				exists: true,
				summary_exists: true,
				summary_file: (.summary_file // $summary_file_rel),
				success_rate: (if ($s.metrics.http_req_failed.value? != null) then (1 - ($s.metrics.http_req_failed.value | tonumber)) else null end),
				failure_rate: ($s.metrics.http_req_failed.value? // null),
				completed_iterations: $completed_iterations,
				interrupted_iterations: (if ($expected_iterations != null and $completed_iterations != null) then ((($expected_iterations | tonumber) - ($completed_iterations | tonumber)) | if . < 0 then 0 else . end) else null end),
				http_req_duration_p95_ms: ($s.metrics.http_req_duration["p(95)"]? // null),
				http_req_duration_p99_ms: ($s.metrics.http_req_duration["p(99)"]? // null)
			}' "$metadata_file")"
	else
		record="$(jq -c \
			--arg file "k6/$k6_slug.metadata.json" \
			--arg summary_file_rel "k6/$k6_slug.summary.json" \
			'. + {
				file: $file,
				exists: true,
				summary_exists: false,
				summary_file: (.summary_file // $summary_file_rel),
				success_rate: null,
				failure_rate: null,
				completed_iterations: null,
				interrupted_iterations: null,
				http_req_duration_p95_ms: null,
				http_req_duration_p99_ms: null
			}' "$metadata_file")"
	fi

	k6_cycle_records="${k6_cycle_records}${k6_cycle_records:+
}$record"
done <<EOF
$expected_k6_labels
EOF

cleanup_records=""
while IFS= read -r cleanup_label; do
	[ -n "$cleanup_label" ] || continue
	cleanup_slug="$(slugify "$cleanup_label")"
	cleanup_file="$artifacts_dir/cleanup/$cleanup_slug.json"

	if [ -f "$cleanup_file" ]; then
		record="$(jq -c \
			--arg file "cleanup/$cleanup_slug.json" \
			'. + {
				file: $file,
				exists: true,
				stale_workload_service_count: (.stale_workload_services | length),
				stale_workload_check_count: (.stale_workload_checks | length)
			}' "$cleanup_file")"
	else
		record="$(jq -nc \
			--arg missing_label "$cleanup_label" \
			--arg file "cleanup/$cleanup_slug.json" \
			'{
				"label": $missing_label,
				file: $file,
				exists: false,
				status: "missing",
				stale_workload_services: [],
				stale_workload_checks: [],
				stale_workload_service_count: 0,
				stale_workload_check_count: 0
			}')"
	fi

	cleanup_records="${cleanup_records}${cleanup_records:+
}$record"
done <<EOF
$expected_cleanup_labels
EOF

scale_cycle_records=""
while IFS= read -r scale_label; do
	[ -n "$scale_label" ] || continue

	if [ -f "$events_file" ]; then
		scale_event_json="$(jq -c -s --arg target_label "$scale_label" 'map(select(.event == "scale-to-zero" and .label == $target_label)) | last' "$events_file")"
	else
		scale_event_json='null'
	fi

	if [ -n "$scale_event_json" ] && [ "$scale_event_json" != "null" ]; then
		record="$(printf '%s' "$scale_event_json" | jq -c --arg file "events.jsonl" '. + {exists: true, source_file: $file}')"
	else
		record="$(jq -nc \
			--arg missing_label "$scale_label" \
			--arg file "events.jsonl" \
			'{
				"label": $missing_label,
				exists: false,
				status: "missing",
				source_file: $file
			}')"
	fi

	scale_cycle_records="${scale_cycle_records}${scale_cycle_records:+
}$record"
done <<EOF
$expected_scale_labels
EOF

state_snapshot_records=""
if [ -d "$artifacts_dir/state" ]; then
	for snapshot_metadata in "$artifacts_dir"/state/*/metadata.json; do
		[ -f "$snapshot_metadata" ] || continue

		snapshot_dir="$(dirname "$snapshot_metadata")"
		snapshot_slug="$(basename "$snapshot_dir")"
		idle_scaler_endpoint=""
		if [ -f "$snapshot_dir/idle-scaler/endpoint.txt" ]; then
			idle_scaler_endpoint="$(tr -d '\n' < "$snapshot_dir/idle-scaler/endpoint.txt")"
		fi
		idle_scaler_healthz_present=false
		[ -s "$snapshot_dir/idle-scaler/healthz.txt" ] && idle_scaler_healthz_present=true
		idle_scaler_metrics_present=false
		[ -s "$snapshot_dir/idle-scaler/metrics.txt" ] && idle_scaler_metrics_present=true

		record="$(jq -c \
			--arg file "state/$snapshot_slug/metadata.json" \
			--arg snapshot_dir_rel "state/$snapshot_slug" \
			--arg idle_scaler_endpoint "$idle_scaler_endpoint" \
			--argjson idle_scaler_healthz_present "$idle_scaler_healthz_present" \
			--argjson idle_scaler_metrics_present "$idle_scaler_metrics_present" \
			'. + {
				file: $file,
				snapshot_dir: $snapshot_dir_rel,
				idle_scaler_endpoint: (if $idle_scaler_endpoint == "" then null else $idle_scaler_endpoint end),
				idle_scaler_healthz_present: $idle_scaler_healthz_present,
				idle_scaler_metrics_present: $idle_scaler_metrics_present
			}' "$snapshot_metadata")"

		state_snapshot_records="${state_snapshot_records}${state_snapshot_records:+
}$record"
	done
fi

if [ -f "$events_file" ]; then
	event_summary_json="$(jq -s '
		{
			present: true,
			total: length,
			counts: (group_by(.event) | map({key: .[0].event, value: length}) | from_entries)
		}
	' "$events_file")"
else
	event_summary_json='{"present":false,"total":0,"counts":{}}'
fi

scenario_results_json="$(json_array_from_records "$scenario_records")"
k6_cycle_records_json="$(json_array_from_records "$k6_cycle_records")"
cleanup_records_json="$(json_array_from_records "$cleanup_records")"
scale_cycle_records_json="$(json_array_from_records "$scale_cycle_records")"
state_snapshot_records_json="$(json_array_from_records "$state_snapshot_records")"

jq -n \
	--slurpfile metadata "$run_metadata_file" \
	--slurpfile run_status "$run_status_file" \
	--arg evaluated_at "$evaluated_at" \
	--arg artifacts_dir "$artifacts_dir" \
	--arg profile_name "$profile_name" \
	--arg run_id "$run_id" \
	--arg release_gates_file "$release_gates_file" \
	--arg release_gates_summary_file "$release_gates_summary_file" \
	--arg idle_scaler_placement "$idle_scaler_placement" \
	--arg idle_scaler_isolation_mode "$idle_scaler_isolation_mode" \
	--argjson idle_scaler_isolation_active "$idle_scaler_isolation_active" \
	--argjson post_initial_scale_to_zero_expected "$post_initial_scale_to_zero_expected" \
	--argjson scenario_results "$scenario_results_json" \
	--argjson k6_cycles "$k6_cycle_records_json" \
	--argjson cleanup_checks "$cleanup_records_json" \
	--argjson scale_cycles "$scale_cycle_records_json" \
	--argjson state_snapshots "$state_snapshot_records_json" \
	--argjson event_summary "$event_summary_json" \
	'
	def number_or_null:
		if . == null or . == "" then null else (tonumber? // null) end;

	def gate($id; $required; $status; $summary; $details):
		{
			id: $id,
			required: $required,
			status: $status,
			summary: $summary,
			details: $details
		};

	($metadata[0] // {}) as $meta
	| ($run_status[0] // {}) as $run
	| ($meta.gates.traffic_success_rate | number_or_null) as $traffic_threshold
	| ($meta.gates.wake_p95_ms | number_or_null) as $wake_p95_threshold
	| ($meta.gates.wake_p99_ms | number_or_null) as $wake_p99_threshold
	| ($meta.gates.scale_to_zero_max_seconds | number_or_null) as $scale_to_zero_max_seconds
	| ($meta.gates.dependency_ready_max_seconds | number_or_null) as $dependency_ready_max_seconds
	| ($scenario_results | map(select(.exists | not) | .scenario_id)) as $scenario_missing
	| ($scenario_results | map(select(.exists and (.status != "passed")) | {scenario: .scenario_id, status: .status})) as $scenario_failed
	| ($k6_cycles | map(select(.exists | not) | .label)) as $k6_missing_metadata
	| ($k6_cycles | map(select(.exists and (.summary_exists | not)) | .label)) as $k6_missing_summaries
	| ($k6_cycles | map(select(.exists and (((.status // "") != "passed") or ((.exit_code // 0) != 0) or ((.interrupted_iterations // 0) > 0))) | {label: .label, status: (.status // "unknown"), exit_code: (.exit_code // null), interrupted_iterations: (.interrupted_iterations // 0)})) as $k6_failed_cycles
	| ($k6_cycles | map(select(.exists and .summary_exists and (.success_rate == null)) | .label)) as $k6_missing_success_rates
	| ($k6_cycles | map(select(.exists and .summary_exists and (.success_rate != null) and $traffic_threshold != null and (.success_rate < $traffic_threshold)) | {label: .label, success_rate: .success_rate})) as $k6_traffic_failures
	| (($k6_cycles | map(select(.success_rate != null) | .success_rate) | min?) // null) as $min_success_rate
	| ($k6_cycles | map(select(.exists and .summary_exists and (.http_req_duration_p95_ms == null or .http_req_duration_p99_ms == null)) | .label)) as $k6_missing_latency
	| ($k6_cycles | map(select(.exists and .summary_exists and .http_req_duration_p95_ms != null and .http_req_duration_p99_ms != null and (($wake_p95_threshold != null and .http_req_duration_p95_ms > $wake_p95_threshold) or ($wake_p99_threshold != null and .http_req_duration_p99_ms > $wake_p99_threshold))) | {label: .label, p95_ms: .http_req_duration_p95_ms, p99_ms: .http_req_duration_p99_ms})) as $k6_latency_failures
	| (($k6_cycles | map(select(.http_req_duration_p95_ms != null) | .http_req_duration_p95_ms) | max?) // null) as $max_p95_ms
	| (($k6_cycles | map(select(.http_req_duration_p99_ms != null) | .http_req_duration_p99_ms) | max?) // null) as $max_p99_ms
	| ($scale_cycles | map(select(.exists | not) | .label)) as $scale_missing
	| ($scale_cycles | map(select(.exists and (.total_duration_ms == null)) | .label)) as $scale_missing_duration
	| ($scale_cycles | map(select(.exists and (((.status // "") != "passed") or ($scale_to_zero_max_seconds != null and .total_duration_ms != null and (.total_duration_ms > ($scale_to_zero_max_seconds * 1000))))) | {label: .label, status: (.status // "unknown"), total_duration_ms: (.total_duration_ms // null)})) as $scale_failures
	| (($scale_cycles | map(select(.total_duration_ms != null) | .total_duration_ms) | max?) // null) as $max_scale_to_zero_duration_ms
	| ($cleanup_checks | map(select(.exists | not) | .label)) as $cleanup_missing
	| ($cleanup_checks | map(select(.exists and (((.status // "") != "passed") or ((.stale_workload_service_count // 0) > 0) or ((.stale_workload_check_count // 0) > 0))) | {label: .label, status: (.status // "unknown"), stale_workload_service_count: (.stale_workload_service_count // 0), stale_workload_check_count: (.stale_workload_check_count // 0)})) as $cleanup_failures
	| (($cleanup_checks | map(select(.duration_ms != null) | .duration_ms) | max?) // null) as $max_cleanup_duration_ms
	| ($scenario_results | map(select(.phase_label == "dead-job-revival" or .phase_label == "idle-scaler-restart"))) as $recovery_scenarios
	| ($recovery_scenarios | map(select(.exists | not) | .scenario_id)) as $recovery_missing
	| ($recovery_scenarios | map(select(.exists and (.recovery_duration_ms == null)) | .scenario_id)) as $recovery_missing_duration
	| ($recovery_scenarios | map(select(.exists and (((.status // "") != "passed") or ($dependency_ready_max_seconds != null and .recovery_duration_ms != null and (.recovery_duration_ms > ($dependency_ready_max_seconds * 1000))))) | {scenario: .scenario_id, status: (.status // "unknown"), recovery_duration_ms: (.recovery_duration_ms // null)})) as $recovery_failures
	| (($recovery_scenarios | map(select(.recovery_duration_ms != null) | .recovery_duration_ms) | max?) // null) as $max_recovery_duration_ms
	| ($k6_cycles | map(select(.wake_duration_ms != null) | {source: .label, duration_ms: .wake_duration_ms})) as $k6_wake_observations
	| ($scenario_results | map(select(.initial_wake_duration_ms != null) | {source: .scenario_id, duration_ms: .initial_wake_duration_ms})) as $initial_wake_observations
	| ($recovery_scenarios | map(select(.recovery_duration_ms != null) | {source: .scenario_id, duration_ms: .recovery_duration_ms})) as $recovery_wake_observations
	| (if (($run.status // "") == "passed" and (($run.exit_code // 1) == 0)) then
			gate(
				"harness-outcome";
				true;
				"passed";
				"Harness completed successfully.";
				{
					run_status: ($run.status // null),
					exit_code: ($run.exit_code // null)
				}
			)
		else
			gate(
				"harness-outcome";
				true;
				"failed";
				("Harness status=" + (($run.status // "unknown") | tostring) + ", exit_code=" + (($run.exit_code // "n/a") | tostring) + ".");
				{
					run_status: ($run.status // null),
					exit_code: ($run.exit_code // null)
				}
			)
		end) as $harness_gate
	| (if ($scenario_results | length) == 0 then
			gate(
				"scenario-coverage";
				true;
				"inconclusive";
				"No requested scenarios were recorded in run metadata.";
				{
					missing_scenarios: [],
					failed_scenarios: []
				}
			)
		elif ($scenario_missing | length) > 0 then
			gate(
				"scenario-coverage";
				true;
				"inconclusive";
				("Missing scenario results: " + ($scenario_missing | join(", ")));
				{
					missing_scenarios: $scenario_missing,
					failed_scenarios: $scenario_failed
				}
			)
		elif ($scenario_failed | length) > 0 then
			gate(
				"scenario-coverage";
				true;
				"failed";
				("Scenario failures: " + ($scenario_failed | map(.scenario + "=" + .status) | join(", ")));
				{
					missing_scenarios: $scenario_missing,
					failed_scenarios: $scenario_failed
				}
			)
		else
			gate(
				"scenario-coverage";
				true;
				"passed";
				("\(($scenario_results | length))/\(($scenario_results | length)) requested scenarios passed.");
				{
					missing_scenarios: $scenario_missing,
					failed_scenarios: $scenario_failed
				}
			)
		end) as $scenario_gate
	| (if ($k6_cycles | length) == 0 then
			gate(
				"k6-coverage";
				false;
				"skipped";
				"No k6 cycles were expected for this run.";
				{
					missing_metadata: [],
					missing_summaries: [],
					failed_cycles: []
				}
			)
		elif ($k6_missing_metadata | length) > 0 or ($k6_missing_summaries | length) > 0 then
			gate(
				"k6-coverage";
				true;
				"inconclusive";
				"Missing k6 metadata or summaries for expected k6 phases.";
				{
					missing_metadata: $k6_missing_metadata,
					missing_summaries: $k6_missing_summaries,
					failed_cycles: $k6_failed_cycles
				}
			)
		elif ($k6_failed_cycles | length) > 0 then
			gate(
				"k6-coverage";
				true;
				"failed";
				"One or more k6 cycles exited non-zero, reported failure, or had interrupted iterations.";
				{
					missing_metadata: $k6_missing_metadata,
					missing_summaries: $k6_missing_summaries,
					failed_cycles: $k6_failed_cycles
				}
			)
		else
			gate(
				"k6-coverage";
				true;
				"passed";
				("\(($k6_cycles | length))/\(($k6_cycles | length)) expected k6 cycles completed with exported summaries.");
				{
					missing_metadata: $k6_missing_metadata,
					missing_summaries: $k6_missing_summaries,
					failed_cycles: $k6_failed_cycles
				}
			)
		end) as $k6_gate
	| (if ($k6_cycles | length) == 0 then
			gate(
				"traffic-success";
				false;
				"skipped";
				"No k6 traffic evidence was expected for this run.";
				{
					threshold: $traffic_threshold,
					worst_success_rate: $min_success_rate,
					missing_success_rates: [],
					failures: []
				}
			)
		elif $traffic_threshold == null then
			gate(
				"traffic-success";
				true;
				"inconclusive";
				"Traffic success threshold is missing from run metadata.";
				{
					threshold: $traffic_threshold,
					worst_success_rate: $min_success_rate,
					missing_success_rates: $k6_missing_success_rates,
					failures: $k6_traffic_failures
				}
			)
		elif ($k6_missing_metadata | length) > 0 or ($k6_missing_summaries | length) > 0 or ($k6_missing_success_rates | length) > 0 then
			gate(
				"traffic-success";
				true;
				"inconclusive";
				"Traffic success evidence is incomplete.";
				{
					threshold: $traffic_threshold,
					worst_success_rate: $min_success_rate,
					missing_success_rates: $k6_missing_success_rates,
					failures: $k6_traffic_failures
				}
			)
		elif ($k6_traffic_failures | length) > 0 then
			gate(
				"traffic-success";
				true;
				"failed";
				("Minimum traffic success rate=" + (($min_success_rate // "n/a") | tostring) + " below threshold=" + ($traffic_threshold | tostring) + ".");
				{
					threshold: $traffic_threshold,
					worst_success_rate: $min_success_rate,
					missing_success_rates: $k6_missing_success_rates,
					failures: $k6_traffic_failures
				}
			)
		else
			gate(
				"traffic-success";
				true;
				"passed";
				("Minimum traffic success rate=" + (($min_success_rate // "n/a") | tostring) + " met threshold=" + ($traffic_threshold | tostring) + ".");
				{
					threshold: $traffic_threshold,
					worst_success_rate: $min_success_rate,
					missing_success_rates: $k6_missing_success_rates,
					failures: $k6_traffic_failures
				}
			)
		end) as $traffic_gate
	| (if ($k6_cycles | length) == 0 then
			gate(
				"latency";
				false;
				"skipped";
				"No k6 latency evidence was expected for this run.";
				{
					thresholds: {
						p95_ms: $wake_p95_threshold,
						p99_ms: $wake_p99_threshold
					},
					worst_p95_ms: $max_p95_ms,
					worst_p99_ms: $max_p99_ms,
					missing_latency: [],
					failures: []
				}
			)
		elif $wake_p95_threshold == null or $wake_p99_threshold == null then
			gate(
				"latency";
				true;
				"inconclusive";
				"Latency thresholds are missing from run metadata.";
				{
					thresholds: {
						p95_ms: $wake_p95_threshold,
						p99_ms: $wake_p99_threshold
					},
					worst_p95_ms: $max_p95_ms,
					worst_p99_ms: $max_p99_ms,
					missing_latency: $k6_missing_latency,
					failures: $k6_latency_failures
				}
			)
		elif ($k6_missing_metadata | length) > 0 or ($k6_missing_summaries | length) > 0 or ($k6_missing_latency | length) > 0 then
			gate(
				"latency";
				true;
				"inconclusive";
				"Latency evidence is incomplete.";
				{
					thresholds: {
						p95_ms: $wake_p95_threshold,
						p99_ms: $wake_p99_threshold
					},
					worst_p95_ms: $max_p95_ms,
					worst_p99_ms: $max_p99_ms,
					missing_latency: $k6_missing_latency,
					failures: $k6_latency_failures
				}
			)
		elif ($k6_latency_failures | length) > 0 then
			gate(
				"latency";
				true;
				"failed";
				("Worst p95=" + (($max_p95_ms // "n/a") | tostring) + "ms, worst p99=" + (($max_p99_ms // "n/a") | tostring) + "ms exceeded thresholds.");
				{
					thresholds: {
						p95_ms: $wake_p95_threshold,
						p99_ms: $wake_p99_threshold
					},
					worst_p95_ms: $max_p95_ms,
					worst_p99_ms: $max_p99_ms,
					missing_latency: $k6_missing_latency,
					failures: $k6_latency_failures
				}
			)
		else
			gate(
				"latency";
				true;
				"passed";
				("Worst p95=" + (($max_p95_ms // "n/a") | tostring) + "ms, worst p99=" + (($max_p99_ms // "n/a") | tostring) + "ms stayed within thresholds.");
				{
					thresholds: {
						p95_ms: $wake_p95_threshold,
						p99_ms: $wake_p99_threshold
					},
					worst_p95_ms: $max_p95_ms,
					worst_p99_ms: $max_p99_ms,
					missing_latency: $k6_missing_latency,
					failures: $k6_latency_failures
				}
			)
		end) as $latency_gate
	| (if ($scale_cycles | length) == 0 then
			gate(
				"scale-cycle";
				false;
				"skipped";
				"No scale-to-zero cycle evidence was expected for this run.";
				{
					threshold_seconds: $scale_to_zero_max_seconds,
					worst_total_duration_ms: $max_scale_to_zero_duration_ms,
					missing_cycles: [],
					missing_duration_cycles: [],
					failures: [],
					wake_observations: {
						k6_cycles: $k6_wake_observations,
						initial_matrix_wakes: $initial_wake_observations,
						recovery_wakes: $recovery_wake_observations
					}
				}
			)
		elif $scale_to_zero_max_seconds == null then
			gate(
				"scale-cycle";
				true;
				"inconclusive";
				"Scale-to-zero threshold is missing from run metadata.";
				{
					threshold_seconds: $scale_to_zero_max_seconds,
					worst_total_duration_ms: $max_scale_to_zero_duration_ms,
					missing_cycles: $scale_missing,
					missing_duration_cycles: $scale_missing_duration,
					failures: $scale_failures,
					wake_observations: {
						k6_cycles: $k6_wake_observations,
						initial_matrix_wakes: $initial_wake_observations,
						recovery_wakes: $recovery_wake_observations
					}
				}
			)
		elif ($scale_missing | length) > 0 or ($scale_missing_duration | length) > 0 then
			gate(
				"scale-cycle";
				true;
				"inconclusive";
				"Scale-to-zero event evidence is incomplete.";
				{
					threshold_seconds: $scale_to_zero_max_seconds,
					worst_total_duration_ms: $max_scale_to_zero_duration_ms,
					missing_cycles: $scale_missing,
					missing_duration_cycles: $scale_missing_duration,
					failures: $scale_failures,
					wake_observations: {
						k6_cycles: $k6_wake_observations,
						initial_matrix_wakes: $initial_wake_observations,
						recovery_wakes: $recovery_wake_observations
					}
				}
			)
		elif ($scale_failures | length) > 0 then
			gate(
				"scale-cycle";
				true;
				"failed";
				("Worst total scale-to-zero duration=" + (($max_scale_to_zero_duration_ms // "n/a") | tostring) + "ms exceeded threshold=" + (($scale_to_zero_max_seconds * 1000) | tostring) + "ms.");
				{
					threshold_seconds: $scale_to_zero_max_seconds,
					worst_total_duration_ms: $max_scale_to_zero_duration_ms,
					missing_cycles: $scale_missing,
					missing_duration_cycles: $scale_missing_duration,
					failures: $scale_failures,
					wake_observations: {
						k6_cycles: $k6_wake_observations,
						initial_matrix_wakes: $initial_wake_observations,
						recovery_wakes: $recovery_wake_observations
					}
				}
			)
		else
			gate(
				"scale-cycle";
				true;
				"passed";
				("Worst total scale-to-zero duration=" + (($max_scale_to_zero_duration_ms // "n/a") | tostring) + "ms stayed within threshold.");
				{
					threshold_seconds: $scale_to_zero_max_seconds,
					worst_total_duration_ms: $max_scale_to_zero_duration_ms,
					missing_cycles: $scale_missing,
					missing_duration_cycles: $scale_missing_duration,
					failures: $scale_failures,
					wake_observations: {
						k6_cycles: $k6_wake_observations,
						initial_matrix_wakes: $initial_wake_observations,
						recovery_wakes: $recovery_wake_observations
					}
				}
			)
		end) as $scale_gate
	| (if ($cleanup_checks | length) == 0 then
			gate(
				"cleanup-consistency";
				false;
				"skipped";
				"No cleanup checks were expected for this run.";
				{
					worst_cleanup_duration_ms: $max_cleanup_duration_ms,
					missing_checks: [],
					failures: []
				}
			)
		elif ($cleanup_missing | length) > 0 then
			gate(
				"cleanup-consistency";
				true;
				"inconclusive";
				"Cleanup evidence is incomplete.";
				{
					worst_cleanup_duration_ms: $max_cleanup_duration_ms,
					missing_checks: $cleanup_missing,
					failures: $cleanup_failures
				}
			)
		elif ($cleanup_failures | length) > 0 then
			gate(
				"cleanup-consistency";
				true;
				"failed";
				"One or more cleanup checks left stale Consul state or timed out.";
				{
					worst_cleanup_duration_ms: $max_cleanup_duration_ms,
					missing_checks: $cleanup_missing,
					failures: $cleanup_failures
				}
			)
		else
			gate(
				"cleanup-consistency";
				true;
				"passed";
				("All \(($cleanup_checks | length)) cleanup checks returned to baseline.");
				{
					worst_cleanup_duration_ms: $max_cleanup_duration_ms,
					missing_checks: $cleanup_missing,
					failures: $cleanup_failures
				}
			)
		end) as $cleanup_gate
	| (if ($recovery_scenarios | length) == 0 then
			gate(
				"recovery-readiness";
				false;
				"skipped";
				"No dependency-ready or recovery scenarios were part of this run.";
				{
					threshold_seconds: $dependency_ready_max_seconds,
					worst_recovery_duration_ms: $max_recovery_duration_ms,
					missing_scenarios: [],
					missing_duration_scenarios: [],
					failures: []
				}
			)
		elif $dependency_ready_max_seconds == null then
			gate(
				"recovery-readiness";
				true;
				"inconclusive";
				"Recovery readiness threshold is missing from run metadata.";
				{
					threshold_seconds: $dependency_ready_max_seconds,
					worst_recovery_duration_ms: $max_recovery_duration_ms,
					missing_scenarios: $recovery_missing,
					missing_duration_scenarios: $recovery_missing_duration,
					failures: $recovery_failures
				}
			)
		elif ($recovery_missing | length) > 0 or ($recovery_missing_duration | length) > 0 then
			gate(
				"recovery-readiness";
				true;
				"inconclusive";
				"Recovery duration evidence is incomplete.";
				{
					threshold_seconds: $dependency_ready_max_seconds,
					worst_recovery_duration_ms: $max_recovery_duration_ms,
					missing_scenarios: $recovery_missing,
					missing_duration_scenarios: $recovery_missing_duration,
					failures: $recovery_failures
				}
			)
		elif ($recovery_failures | length) > 0 then
			gate(
				"recovery-readiness";
				true;
				"failed";
				("Worst recovery duration=" + (($max_recovery_duration_ms // "n/a") | tostring) + "ms exceeded threshold=" + (($dependency_ready_max_seconds * 1000) | tostring) + "ms.");
				{
					threshold_seconds: $dependency_ready_max_seconds,
					worst_recovery_duration_ms: $max_recovery_duration_ms,
					missing_scenarios: $recovery_missing,
					missing_duration_scenarios: $recovery_missing_duration,
					failures: $recovery_failures
				}
			)
		else
			gate(
				"recovery-readiness";
				true;
				"passed";
				("Worst recovery duration=" + (($max_recovery_duration_ms // "n/a") | tostring) + "ms stayed within threshold.");
				{
					threshold_seconds: $dependency_ready_max_seconds,
					worst_recovery_duration_ms: $max_recovery_duration_ms,
					missing_scenarios: $recovery_missing,
					missing_duration_scenarios: $recovery_missing_duration,
					failures: $recovery_failures
				}
			)
		end) as $recovery_gate
	| [$harness_gate, $scenario_gate, $k6_gate, $traffic_gate, $latency_gate, $scale_gate, $cleanup_gate, $recovery_gate] as $gates
	| (if any($gates[]; .required and .status == "failed") then
			"failed"
		elif any($gates[]; .required and .status == "inconclusive") then
			"inconclusive"
		else
			"passed"
		end) as $overall_status
	| (if $overall_status == "passed" then "go" else "no-go" end) as $decision
	| (if $overall_status == "passed" then 0 elif $overall_status == "failed" then 1 else 2 end) as $exit_code
	| {
		run_id: ($meta.run_id // $run.run_id // $run_id),
		evaluated_at: $evaluated_at,
		artifacts_dir: $artifacts_dir,
		profile: ($meta.profile // {name: $profile_name}),
		idle_scaler: {
			placement: ($meta.idle_scaler.placement // $meta.topology.idle_scaler_placement // $idle_scaler_placement),
			isolation_mode: ($meta.idle_scaler.isolation_mode // $idle_scaler_isolation_mode),
			isolation_active: (if (($meta.idle_scaler | type) == "object" and ($meta.idle_scaler | has("isolation_active"))) then $meta.idle_scaler.isolation_active else $idle_scaler_isolation_active end),
			post_initial_scale_to_zero_expected: (if (($meta.idle_scaler | type) == "object" and ($meta.idle_scaler | has("post_initial_scale_to_zero_expected"))) then $meta.idle_scaler.post_initial_scale_to_zero_expected else $post_initial_scale_to_zero_expected end)
		},
		scenario_plan: ($meta.scenario_plan // {
			requested: ($scenario_results | map(.scenario_id)),
			effective: ($scenario_results | map(.scenario_id)),
			excluded: []
		}),
		decision: $decision,
		status: $overall_status,
		exit_code: $exit_code,
		thresholds: {
			traffic_success_rate: $traffic_threshold,
			wake_p95_ms: $wake_p95_threshold,
			wake_p99_ms: $wake_p99_threshold,
			scale_to_zero_max_seconds: $scale_to_zero_max_seconds,
			dependency_ready_max_seconds: $dependency_ready_max_seconds
		},
		summary: {
			requested_scenarios: ($scenario_results | length),
			expected_k6_cycles: ($k6_cycles | length),
			expected_scale_cycles: ($scale_cycles | length),
			cleanup_checks: ($cleanup_checks | length),
			state_snapshots: ($state_snapshots | length),
			event_count: ($event_summary.total // 0),
			worst_traffic_success_rate: $min_success_rate,
			worst_latency_p95_ms: $max_p95_ms,
			worst_latency_p99_ms: $max_p99_ms,
			worst_scale_to_zero_duration_ms: $max_scale_to_zero_duration_ms,
			worst_recovery_duration_ms: $max_recovery_duration_ms
		},
		output: {
			release_gates_file: $release_gates_file,
			release_gates_summary_file: $release_gates_summary_file
		},
		events: $event_summary,
		artifacts: {
			run_metadata_file: "run-metadata.json",
			run_status_file: "run-status.json",
			events_file: (if $event_summary.present then "events.jsonl" else null end),
			scenario_results: $scenario_results,
			k6_cycles: $k6_cycles,
			cleanup_checks: $cleanup_checks,
			scale_to_zero_cycles: $scale_cycles,
			state_snapshots: {
				count: ($state_snapshots | length),
				labels: ($state_snapshots | map(.label)),
				items: $state_snapshots
			}
		},
		gates: $gates
	}
	' > "$release_gates_file"

emit_summary
exit "$(jq -r '.exit_code' "$release_gates_file")"
