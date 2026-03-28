#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

workload_mix_labels="${E2E_WORKLOAD_MIX_LABELS:-fast-api,slow-start,dependency-sensitive}"
idle_timeout="${E2E_IDLE_TIMEOUT:-10s}"
job_cpu="${E2E_JOB_CPU:-50}"
job_memory="${E2E_JOB_MEMORY:-64}"
job_check_interval="${E2E_JOB_CHECK_INTERVAL:-2s}"
job_check_timeout="${E2E_JOB_CHECK_TIMEOUT:-2s}"
job_check_path="${E2E_JOB_CHECK_PATH:-/readyz}"
traefik_internal_url="${E2E_TRAEFIK_INTERNAL_URL:-${E2E_TRAEFIK_BASE_URL:-http://traefik:80}}"
generated_dir="${E2E_GENERATED_DIR:-$ROOT_DIR/.e2e-generated}"
output_dir="${E2E_GENERATED_JOBS_DIR:-${generated_dir}/jobs}"
manifest_file="${E2E_WORKLOAD_MANIFEST_FILE:-${generated_dir}/workload-manifest.tsv}"
render_vars='${E2E_RENDER_SERVICE_NAME} ${E2E_RENDER_HOST_NAME} ${E2E_RENDER_JOB_NAME} ${E2E_RENDER_IDLE_TIMEOUT} ${E2E_RENDER_JOB_SPEC_KEY} ${E2E_RENDER_JOB_CPU} ${E2E_RENDER_JOB_MEMORY} ${E2E_RENDER_JOB_CHECK_INTERVAL} ${E2E_RENDER_JOB_CHECK_TIMEOUT} ${E2E_RENDER_JOB_CHECK_PATH} ${E2E_RENDER_WORKLOAD_CLASS} ${E2E_RENDER_WORKLOAD_ORDINAL} ${E2E_RENDER_RESPONSE_MODE} ${E2E_RENDER_RESPONSE_TEXT} ${E2E_RENDER_STARTUP_DELAY} ${E2E_RENDER_HEALTH_MODE} ${E2E_RENDER_DEPENDENCY_URL} ${E2E_RENDER_DEPENDENCY_HOST} ${E2E_RENDER_DEPENDENCY_TIMEOUT}'

trim_label() {
  printf '%s' "$1" | tr -d '[:space:]'
}

workload_key() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_' | tr -cd 'A-Z0-9_'
}

workload_var_name() {
  label="$1"
  suffix="$2"
  printf 'E2E_WORKLOAD_%s_%s' "$(workload_key "$label")" "$suffix"
}

workload_count() {
  label="$1"
  count_var_name="$(workload_var_name "$label" COUNT)"
  eval "count_value=\${$count_var_name:-0}"
  case "$count_value" in
    ''|*[!0-9]*)
      echo "Invalid ${count_var_name}: ${count_value}" >&2
      exit 1
      ;;
  esac
  printf '%s' "$count_value"
}

workload_value() {
  label="$1"
  suffix="$2"
  fallback="$3"
  value_var_name="$(workload_var_name "$label" "$suffix")"
  eval "value=\${$value_var_name:-}"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

plan_entry_count_for_class() {
  plan_entries="$1"
  workload_class="$2"
  printf '%s\n' "$plan_entries" | awk -F'|' -v workload_class="$workload_class" '$2 == workload_class { count++ } END { print count + 0 }'
}

default_dependency_host_for_render() {
  workload_class="$1"
  workload_ordinal="$2"
  fallback="$3"

  if [ "$workload_class" != "dependency-sensitive" ]; then
    printf '%s' "$fallback"
    return 0
  fi

  if [ -z "${fast_api_hosts:-}" ]; then
    printf '%s' "$fallback"
    return 0
  fi

  host_count="$(printf '%s\n' "$fast_api_hosts" | awk 'NF { count++ } END { print count + 0 }')"
  if [ "$host_count" -eq 0 ]; then
    printf '%s' "$fallback"
    return 0
  fi

  host_index=$(( ((workload_ordinal - 1) % host_count) + 1 ))
  printf '%s\n' "$fast_api_hosts" | awk -v host_index="$host_index" 'NF { count++; if (count == host_index) { print; exit } }'
}

remaining_var_name() {
  printf 'E2E_RENDER_REMAINING_%s' "$(workload_key "$1")"
}

sequence_var_name() {
  printf 'E2E_RENDER_SEQUENCE_%s' "$(workload_key "$1")"
}

set_workload_remaining() {
  label="$1"
  remaining="$2"
  var_name="$(remaining_var_name "$label")"
  eval "$var_name=$remaining"
}

get_workload_remaining() {
  label="$1"
  var_name="$(remaining_var_name "$label")"
  eval "printf '%s' \"\${$var_name:-0}\""
}

initialize_workload_sequence() {
  label="$1"
  var_name="$(sequence_var_name "$label")"
  eval "$var_name=0"
}

next_workload_sequence() {
  label="$1"
  var_name="$(sequence_var_name "$label")"
  eval "current=\${$var_name:-0}"
  current=$((current + 1))
  eval "$var_name=$current"
  printf '%s' "$current"
}

set_workload_defaults() {
  class="$1"

  default_job_cpu="$job_cpu"
  default_job_memory="$job_memory"
  default_idle_timeout="$idle_timeout"
  default_job_check_interval="$job_check_interval"
  default_job_check_timeout="$job_check_timeout"
  default_job_check_path="$job_check_path"
  default_response_mode="text"
  default_startup_delay="0s"
  default_health_mode="startup-gated"
  default_dependency_url=""
  default_dependency_host=""
  default_dependency_timeout="10s"

  case "$class" in
    fast-api)
      default_response_mode="json"
      ;;
    slow-start)
      default_startup_delay="12s"
      ;;
    dependency-sensitive)
      default_response_mode="json"
      default_startup_delay="2s"
      default_health_mode="dependency-gated"
      default_dependency_url="$traefik_internal_url"
      default_dependency_host="$fast_api_primary_host"
      ;;
  esac

  if [ "$default_health_mode" = "dependency-gated" ] && [ -z "$default_dependency_host" ]; then
    default_health_mode="startup-gated"
    default_dependency_url=""
  fi
}

mkdir -p "$output_dir"
rm -f "$output_dir"/*.nomad
: > "$manifest_file"

mix_labels=""
job_count=0
workload_summary=""
for raw_label in $(printf '%s' "$workload_mix_labels" | tr ',' ' '); do
  workload_class="$(trim_label "$raw_label")"
  [ -n "$workload_class" ] || continue

  class_count="$(workload_count "$workload_class")" || exit 1
  set_workload_remaining "$workload_class" "$class_count"
  initialize_workload_sequence "$workload_class"
  job_count=$((job_count + class_count))

  if [ -n "$mix_labels" ]; then
    mix_labels="$mix_labels $workload_class"
    workload_summary="$workload_summary, "
  else
    mix_labels="$workload_class"
  fi
  workload_summary="${workload_summary}${workload_class}=${class_count}"
done

if [ -z "$mix_labels" ]; then
  echo "No workload classes configured via E2E_WORKLOAD_MIX_LABELS" >&2
  exit 1
fi

if [ "$job_count" -eq 0 ]; then
  echo "No workload jobs configured; rendered 0 jobs into ${output_dir}"
  exit 0
fi

plan=""
fast_api_primary_host=""
fast_api_hosts=""
job_number=1
while [ "$job_number" -le "$job_count" ]; do
  assigned_in_cycle=0
  for workload_class in $mix_labels; do
    [ "$job_number" -le "$job_count" ] || break

    remaining_jobs="$(get_workload_remaining "$workload_class")"
    [ "$remaining_jobs" -gt 0 ] || continue

    workload_ordinal=$(( $(plan_entry_count_for_class "$plan" "$workload_class") + 1 ))
    set_workload_remaining "$workload_class" $((remaining_jobs - 1))

    job_name="$(printf 'echo-s2z-%04d' "$job_number")"
    if [ "$workload_class" = "fast-api" ]; then
      fast_api_host="${job_name}.localhost"
      if [ -z "$fast_api_primary_host" ]; then
        fast_api_primary_host="$fast_api_host"
      fi
      fast_api_hosts="${fast_api_hosts}${fast_api_hosts:+
}${fast_api_host}"
    fi

    plan="${plan}${job_name}|${workload_class}|${workload_ordinal}
"
    job_number=$((job_number + 1))
    assigned_in_cycle=1
  done

  if [ "$assigned_in_cycle" -eq 0 ]; then
    echo "Failed to generate a workload plan from ${workload_mix_labels}" >&2
    exit 1
  fi
done

printf '%s' "$plan" | while IFS='|' read -r job_name workload_class workload_ordinal; do
  [ -n "$job_name" ] || continue

  set_workload_defaults "$workload_class"

  service_name="$job_name"
  host_name="${service_name}.localhost"
  job_spec_key="scale-to-zero/jobs/${job_name}"

  render_job_cpu="$(workload_value "$workload_class" CPU "$default_job_cpu")"
  render_job_memory="$(workload_value "$workload_class" MEMORY "$default_job_memory")"
  render_idle_timeout="$(workload_value "$workload_class" IDLE_TIMEOUT "$default_idle_timeout")"
  render_job_check_interval="$(workload_value "$workload_class" CHECK_INTERVAL "$default_job_check_interval")"
  render_job_check_timeout="$(workload_value "$workload_class" CHECK_TIMEOUT "$default_job_check_timeout")"
  render_job_check_path="$(workload_value "$workload_class" CHECK_PATH "$default_job_check_path")"
  render_response_mode="$(workload_value "$workload_class" RESPONSE_MODE "$default_response_mode")"
  render_startup_delay="$(workload_value "$workload_class" STARTUP_DELAY "$default_startup_delay")"
  render_health_mode="$(workload_value "$workload_class" HEALTH_MODE "$default_health_mode")"
  render_dependency_url="$(workload_value "$workload_class" DEPENDENCY_URL "$default_dependency_url")"
  render_dependency_fallback="$(default_dependency_host_for_render "$workload_class" "$workload_ordinal" "$default_dependency_host")"
  render_dependency_host="$(workload_value "$workload_class" DEPENDENCY_HOST "$render_dependency_fallback")"
  render_dependency_timeout="$(workload_value "$workload_class" DEPENDENCY_TIMEOUT "$default_dependency_timeout")"
  render_response_text="$(workload_value "$workload_class" RESPONSE_TEXT "Hello from ${service_name} (${workload_class})")"

  if [ "$render_health_mode" = "dependency-gated" ] && [ -z "$render_dependency_host" ]; then
    render_health_mode="startup-gated"
    render_dependency_url=""
  fi

  export E2E_RENDER_SERVICE_NAME="$service_name"
  export E2E_RENDER_HOST_NAME="$host_name"
  export E2E_RENDER_JOB_NAME="$job_name"
  export E2E_RENDER_IDLE_TIMEOUT="$render_idle_timeout"
  export E2E_RENDER_JOB_SPEC_KEY="$job_spec_key"
  export E2E_RENDER_JOB_CPU="$render_job_cpu"
  export E2E_RENDER_JOB_MEMORY="$render_job_memory"
  export E2E_RENDER_JOB_CHECK_INTERVAL="$render_job_check_interval"
  export E2E_RENDER_JOB_CHECK_TIMEOUT="$render_job_check_timeout"
  export E2E_RENDER_JOB_CHECK_PATH="$render_job_check_path"
  export E2E_RENDER_WORKLOAD_CLASS="$workload_class"
  export E2E_RENDER_WORKLOAD_ORDINAL="$workload_ordinal"
  export E2E_RENDER_RESPONSE_MODE="$render_response_mode"
  export E2E_RENDER_RESPONSE_TEXT="$render_response_text"
  export E2E_RENDER_STARTUP_DELAY="$render_startup_delay"
  export E2E_RENDER_HEALTH_MODE="$render_health_mode"
  export E2E_RENDER_DEPENDENCY_URL="$render_dependency_url"
  export E2E_RENDER_DEPENDENCY_HOST="$render_dependency_host"
  export E2E_RENDER_DEPENDENCY_TIMEOUT="$render_dependency_timeout"

  envsubst "$render_vars" < "$ROOT_DIR"/e2e/nomad/jobs/echo-s2z.nomad.tpl > "$output_dir/${job_name}.nomad"
  printf '%s|%s|%s|%s|%s\n' \
    "$job_name" \
    "$service_name" \
    "$workload_class" \
    "$workload_ordinal" \
    "$job_spec_key" >> "$manifest_file"
done

echo "Rendered ${job_count} workload jobs into ${output_dir} (${workload_summary})"
echo "Wrote workload manifest to ${manifest_file}"
