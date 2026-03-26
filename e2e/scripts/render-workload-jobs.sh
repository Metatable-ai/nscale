#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

job_count="${E2E_JOB_COUNT:-10}"
idle_timeout="${E2E_IDLE_TIMEOUT:-10s}"
output_dir="/tmp/e2e-generated/jobs"
render_vars='${E2E_RENDER_SERVICE_NAME} ${E2E_RENDER_HOST_NAME} ${E2E_RENDER_JOB_NAME} ${E2E_RENDER_IDLE_TIMEOUT} ${E2E_RENDER_JOB_SPEC_KEY}'

mkdir -p "$output_dir"

i=1
while [ "$i" -le "$job_count" ]; do
  service_name="$(printf 'echo-s2z-%04d' "$i")"
  host_name="${service_name}.localhost"
  job_name="$service_name"
  job_spec_key="scale-to-zero/jobs/${job_name}"

  export E2E_RENDER_SERVICE_NAME="$service_name"
  export E2E_RENDER_HOST_NAME="$host_name"
  export E2E_RENDER_JOB_NAME="$job_name"
  export E2E_RENDER_IDLE_TIMEOUT="$idle_timeout"
  export E2E_RENDER_JOB_SPEC_KEY="$job_spec_key"

  envsubst "$render_vars" < "$ROOT_DIR"/e2e/nomad/jobs/echo-s2z.nomad.tpl > "$output_dir/${job_name}.nomad"
  i=$((i + 1))
done

echo "Rendered ${job_count} workload jobs into ${output_dir}"