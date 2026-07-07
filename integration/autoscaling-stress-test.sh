#!/usr/bin/env bash
# autoscaling-stress-test.sh — many-job autoscaling stress runner.
#
# Exercises many independent per-job autoscaling policies at once:
#   N jobs start at 0, receive concurrent traffic, scale to max_count=2,
#   then return to 0 after traffic stops.
#
# Usage:
#   ./autoscaling-stress-test.sh --start
#   ./autoscaling-stress-test.sh --start --job-count=10 --duration=180
#   ./autoscaling-stress-test.sh --job-count=6
#   ./autoscaling-stress-test.sh --start --job-count=50 --duration=240
#   ./autoscaling-stress-test.sh --start --job-count=50 --setup-concurrency=10
#   ./autoscaling-stress-test.sh --start --job-count=6 --require-caps

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ECHO_JOB_FILE="$SCRIPT_DIR/jobs/autoscale-echo.nomad"
TRAEFIK_CERT_SCRIPT="$SCRIPT_DIR/traefik/certs/generate.sh"

NOMAD_ADDR="http://localhost:4646"
NSCALE_PROXY="http://localhost:80"
NSCALE_ADMIN="http://localhost:9090"
GROUP="main"

START_INFRA=false
JOB_COUNT=50
DURATION_SECS=240
MAX_COUNT=""
RESULTS_DIR=""
SETUP_CONCURRENCY=8
PHASED_TRAFFIC=true
REQUIRE_CAPS=false
CAP_WAIT_SECS=300
ZERO_WAIT_SECS=480

for arg in "$@"; do
  case "$arg" in
    --start) START_INFRA=true ;;
    --job-count=*) JOB_COUNT="${arg#*=}" ;;
    --duration=*) DURATION_SECS="${arg#*=}" ;;
    --max-count=*) MAX_COUNT="${arg#*=}" ;;
    --setup-concurrency=*) SETUP_CONCURRENCY="${arg#*=}" ;;
    --steady-traffic) PHASED_TRAFFIC=false ;;
    --require-caps) REQUIRE_CAPS=true ;;
    --cap-wait=*) CAP_WAIT_SECS="${arg#*=}" ;;
    --zero-wait=*) ZERO_WAIT_SECS="${arg#*=}" ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
pass()   { echo -e "${GREEN}✓ $1${NC}"; }
fail()   { echo -e "${RED}✗ $1${NC}"; exit 1; }
info()   { echo -e "${YELLOW}→ $1${NC}"; }
header() { echo -e "\n${CYAN}══ $1 ══${NC}"; }

PRESSURE_PIDS=""

cleanup() {
  local exit_code=$?
  for pid in ${PRESSURE_PIDS:-}; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done

  if [ "$exit_code" -ne 0 ]; then
    info "Autoscaling stress failed; collecting diagnostics..."
    docker compose -f "$COMPOSE_FILE" logs --tail=300 nscale nomad traefik || true
    curl -fsS "$NSCALE_ADMIN/metrics" | grep -E 'nscale_autoscale|nscale_proxy_requests' || true
    docker compose -f "$COMPOSE_FILE" exec -T traefik wget -qO- http://127.0.0.1:8082/metrics \
      | grep -E 'traefik_(service|router)_requests_total' || true
  fi

  if [ -n "${RESULTS_DIR:-}" ] && [ -d "$RESULTS_DIR" ]; then
    info "Request result files preserved at: $RESULTS_DIR"
  fi
}
trap cleanup EXIT

nomad_count() {
  local job_id="$1"
  curl -s "$NOMAD_ADDR/v1/job/${job_id}" | jq '.TaskGroups[0].Count'
}

wait_for_job_count_exact() {
  local job_id="$1"
  local expected="$2"
  local timeout="${3:-180}"
  local elapsed=0

  while [ "$elapsed" -lt "$timeout" ]; do
    local count
    count=$(nomad_count "$job_id" 2>/dev/null || echo 0)
    echo "  ... ${elapsed}s ${job_id} count=${count}, expecting ${expected}"
    [ "$count" -eq "$expected" ] && return 0
    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "${job_id} did not reach count ${expected} within ${timeout}s"
}

wait_for_job_count_at_least() {
  local job_id="$1"
  local expected="$2"
  local timeout="${3:-180}"
  local elapsed=0

  while [ "$elapsed" -lt "$timeout" ]; do
    local count
    count=$(nomad_count "$job_id" 2>/dev/null || echo 0)
    echo "  ... ${elapsed}s ${job_id} count=${count}, expecting >= ${expected}"
    [ "$count" -ge "$expected" ] && return 0
    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "${job_id} did not reach count >= ${expected} within ${timeout}s"
}

wait_for_all_count_exact() {
  local expected="$1"
  local timeout="$2"
  shift 2
  local job_ids=("$@")
  local elapsed=0

  while [ "$elapsed" -lt "$timeout" ]; do
    local all_ok=true
    local summary=""
    for job_id in "${job_ids[@]}"; do
      local count
      count=$(nomad_count "$job_id" 2>/dev/null || echo 0)
      summary+=" ${job_id}=${count}"
      if [ "$count" -ne "$expected" ]; then
        all_ok=false
      fi
    done
    echo "  ... ${elapsed}s expecting all=${expected}:${summary}"
    $all_ok && return 0
    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "Not all jobs reached count ${expected} within ${timeout}s"
}

wait_for_all_saw_min_before_zero() {
  local timeout="$1"
  local job_ids=("${JOB_IDS[@]}")
  local seen_min=()
  local done=()
  local elapsed=0
  local idx

  for idx in "${!job_ids[@]}"; do
    seen_min[$idx]=0
    done[$idx]=0
  done

  while [ "$elapsed" -lt "$timeout" ]; do
    local all_done=true
    local summary=""
    for idx in "${!job_ids[@]}"; do
      local job_id="${job_ids[$idx]}"
      local min_count="${JOB_MIN_COUNTS[$idx]}"
      local count
      count=$(nomad_count "$job_id" 2>/dev/null || echo 0)
      if [ "$count" -eq 0 ]; then
        if [ "${seen_min[$idx]}" -ne 1 ]; then
          fail "${job_id} reached zero before being observed at or below min_count=${min_count}"
        fi
        done[$idx]=1
      fi
      if [ "$count" -le "$min_count" ] && [ "$count" -gt 0 ]; then
        seen_min[$idx]=1
      fi
      summary+=" ${job_id}=${count}/seen_min:${seen_min[$idx]}/done:${done[$idx]}"
      [ "${done[$idx]}" -eq 1 ] || all_done=false
    done
    echo "  ... ${elapsed}s waiting for all zero after min:${summary}"
    $all_done && return 0
    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "Not all jobs reached zero after min_count within ${timeout}s"
}

wait_for_all_reached_caps() {
  local timeout="$1"
  local elapsed=0

  while [ "$elapsed" -lt "$timeout" ]; do
    local all_ok=true
    local summary=""
    local idx
    for idx in "${!JOB_IDS[@]}"; do
      local job_id="${JOB_IDS[$idx]}"
      local cap="${JOB_MAX_COUNTS[$idx]}"
      local count
      count=$(nomad_count "$job_id" 2>/dev/null || echo 0)
      summary+=" ${job_id}=${count}/${cap}"
      if [ "$count" -gt "$cap" ]; then
        fail "${job_id} exceeded cap ${cap}; actual=${count}"
      fi
      if [ "$count" -ne "$cap" ]; then
        all_ok=false
      fi
    done
    echo "  ... ${elapsed}s waiting for all caps:${summary}"
    $all_ok && return 0
    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "Not all jobs reached their caps within ${timeout}s"
}

observe_scale_for() {
  local duration="$1"
  local elapsed=0

  JOB_PEAK_COUNTS=()
  for _ in "${JOB_IDS[@]}"; do
    JOB_PEAK_COUNTS+=(0)
  done

  while [ "$elapsed" -lt "$duration" ]; do
    local summary=""
    local idx
    for idx in "${!JOB_IDS[@]}"; do
      local job_id="${JOB_IDS[$idx]}"
      local cap="${JOB_MAX_COUNTS[$idx]}"
      local count
      count=$(nomad_count "$job_id" 2>/dev/null || echo 0)
      if [ "$count" -gt "$cap" ]; then
        fail "${job_id} exceeded cap ${cap}; actual=${count}"
      fi
      if [ "$count" -gt "${JOB_PEAK_COUNTS[$idx]}" ]; then
        JOB_PEAK_COUNTS[$idx]="$count"
      fi
      summary+=" ${job_id}=${count}/${cap}/peak:${JOB_PEAK_COUNTS[$idx]}"
    done
    echo "  ... ${elapsed}s observing scale:${summary}"
    sleep 5
    elapsed=$((elapsed + 5))
  done
}

wait_for_deployment_complete() {
  local job_id="$1"
  local timeout="${2:-120}"
  local elapsed=0

  while [ "$elapsed" -lt "$timeout" ]; do
    if curl -s "$NOMAD_ADDR/v1/job/${job_id}/deployments" \
      | jq -e 'length == 0 or all(.[]; (.Status // "unknown") == "successful" or (.Status // "unknown") == "failed" or (.Status // "unknown") == "cancelled")' >/dev/null; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  fail "Deployment for ${job_id} did not complete within ${timeout}s"
}

assert_job_count_at_most() {
  local job_id="$1"
  local max_count="$2"
  local count
  count=$(nomad_count "$job_id")
  [ "$count" -le "$max_count" ] || fail "${job_id} exceeded cap ${max_count}; actual=${count}"
}

max_count_for_index() {
  local idx="$1"
  if [ -n "$MAX_COUNT" ]; then
    echo "$MAX_COUNT"
  else
    # Alternate between 2 and 3 instances to keep dev Nomad load reasonable
    # while still proving per-job caps differ.
    echo $((2 + ((idx + 1) % 2)))
  fi
}

submit_generated_echo_job() {
  local job_id="$1"
  local service_name="$2"
  local policy_json="$3"
  local hcl variables payload response code body

  hcl=$(perl \
    -0pe 's/job "autoscale-echo"/job "'$job_id'"/g; s#/tmp/autoscale-echo-www#/tmp/'$job_id'-www#g' \
    <"$ECHO_JOB_FILE")
  variables=$(cat <<EOF
service_name = "${service_name}"
host_name = "${service_name}.localhost"
EOF
)

  payload=$(jq -n \
    --arg hcl "$hcl" \
    --arg variables "$variables" \
    --argjson autoscaling "$policy_json" \
    '{hcl: $hcl, variables: $variables, autoscaling: $autoscaling}')

  response=$(curl -sS -w "\n%{http_code}" -X POST "$NSCALE_ADMIN/admin/jobs" \
    -H "Content-Type: application/json" \
    -d "$payload")
  code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [ "$code" != "201" ]; then
    echo "$body" | jq . || echo "$body"
    fail "Generated autoscale job submission failed for ${job_id}/${service_name}: HTTP ${code}"
  fi
}

force_scale_to_zero() {
  local job_id="$1"
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$NOMAD_ADDR/v1/job/${job_id}/scale" \
    -H "Content-Type: application/json" \
    -d "{\"Count\":0,\"Target\":{\"Group\":\"${GROUP}\"},\"Message\":\"autoscaling stress: start from zero\"}")
  [[ "$code" =~ ^2 ]] || fail "Failed to scale ${job_id} to zero: HTTP ${code}"
  wait_for_job_count_exact "$job_id" 0 120
}

purge_job() {
  local job_id="$1"
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$NSCALE_ADMIN/admin/jobs/${job_id}?force=true")
  [[ "$code" =~ ^2 ]] || [ "$code" = "404" ] || fail "Failed to purge ${job_id}: HTTP ${code}"
}

prepare_job() {
  local idx="$1"
  local job_id="autoscale-many-${idx}"
  local service_name="real-many-${idx}"
  local max_count
  local policy

  max_count=$(max_count_for_index "$idx")
  policy=$(jq -n \
    --argjson max_count "$max_count" \
    '{max_count:$max_count,min_count:1,scale_to_zero:true,scale_up_step:1,scale_down_step:1,cooldown_secs:15,decision_window_secs:20,target_requests_per_second_per_instance:1.0,target_p95_latency_ms:500.0}')

  echo "  preparing ${job_id} service=${service_name} max_count=${max_count}"
  purge_job "$job_id" || true
  submit_generated_echo_job "$job_id" "$service_name" "$policy"
  wait_for_job_count_at_least "$job_id" 1 120
  wait_for_deployment_complete "$job_id"
  force_scale_to_zero "$job_id"
  echo "  prepared ${job_id}"
}

start_pressure() {
  local service_name="$1"
  local duration_secs="$2"
  local result_file="$3"
  local idx="$4"
  (
    local ok=0
    local fail_count=0
    local end
    local sleep_secs="0.2"
    if $PHASED_TRAFFIC; then
      local high_secs=$((duration_secs * 2 / 3))
      local low_secs=$((duration_secs - high_secs))
      local high_end=$((SECONDS + high_secs))
      end=$((SECONDS + duration_secs))
      # Stagger high rates a bit per job: 0.10, 0.15, 0.20 seconds.
      sleep_secs=$(awk "BEGIN { printf \"%.2f\", 0.10 + (($idx - 1) % 3) * 0.05 }")
      while [ "$SECONDS" -lt "$high_end" ]; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${service_name}.localhost" "${NSCALE_PROXY}/cgi-bin/slow?delay=1" --max-time 10 || echo 000)
        if [ "$code" = "200" ]; then ok=$((ok + 1)); else fail_count=$((fail_count + 1)); fi
        sleep "$sleep_secs"
      done
      # Low traffic phase: keep occasional real requests flowing before full stop.
      while [ "$SECONDS" -lt "$end" ]; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${service_name}.localhost" "${NSCALE_PROXY}/" --max-time 10 || echo 000)
        if [ "$code" = "200" ]; then ok=$((ok + 1)); else fail_count=$((fail_count + 1)); fi
        sleep 2
      done
    else
      end=$((SECONDS + duration_secs))
      while [ "$SECONDS" -lt "$end" ]; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${service_name}.localhost" "${NSCALE_PROXY}/cgi-bin/slow?delay=1" --max-time 10 || echo 000)
        if [ "$code" = "200" ]; then ok=$((ok + 1)); else fail_count=$((fail_count + 1)); fi
        sleep "$sleep_secs"
      done
    fi
    printf 'service=%s ok=%s failed=%s\n' "$service_name" "$ok" "$fail_count" >"$result_file"
  ) &
  PRESSURE_PIDS="${PRESSURE_PIDS} $!"
}

summarize_request_results() {
  local total_ok=0
  local total_failed=0
  local file

  header "Request results"
  for file in "$RESULTS_DIR"/*.txt; do
    [ -f "$file" ] || continue
    cat "$file"
    local ok failed
    ok=$(sed -n 's/.* ok=\([0-9][0-9]*\).*/\1/p' "$file")
    failed=$(sed -n 's/.* failed=\([0-9][0-9]*\).*/\1/p' "$file")
    total_ok=$((total_ok + ok))
    total_failed=$((total_failed + failed))
  done
  info "Total handled requests: ok=${total_ok} failed=${total_failed}"
  [ "$total_ok" -gt 0 ] || fail "No successful requests were handled"
  [ "$total_failed" -eq 0 ] || fail "Some pressure requests failed: ${total_failed}"
}

summarize_scale_results() {
  local reached_cap=0
  local reached_nonzero=0
  local idx

  header "Scale results"
  for idx in "${!JOB_IDS[@]}"; do
    local job_id="${JOB_IDS[$idx]}"
    local cap="${JOB_MAX_COUNTS[$idx]}"
    local peak="${JOB_PEAK_COUNTS[$idx]:-0}"
    echo "job=${job_id} cap=${cap} peak=${peak}"
    [ "$peak" -gt 0 ] && reached_nonzero=$((reached_nonzero + 1))
    [ "$peak" -eq "$cap" ] && reached_cap=$((reached_cap + 1))
  done

  info "Jobs with traffic-driven nonzero count: ${reached_nonzero}/${JOB_COUNT}"
  info "Jobs that reached configured cap: ${reached_cap}/${JOB_COUNT}"
  [ "$reached_nonzero" -gt 0 ] || fail "No jobs reached nonzero count under pressure"
}

header "Pre-flight checks"
for cmd in docker curl jq openssl perl awk; do
  command -v "$cmd" >/dev/null || fail "Required command '$cmd' not found"
done
pass "Prerequisites OK"

bash "$TRAEFIK_CERT_SCRIPT"

if $START_INFRA; then
  header "Starting infrastructure"
  cd "$SCRIPT_DIR"
  docker compose -f "$COMPOSE_FILE" up -d --build
fi

header "Infrastructure health"
elapsed=0
while true; do
  [ "$elapsed" -ge 120 ] && fail "Infrastructure did not become healthy within 120s"
  all_health=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
    | jq -r 'select(.Service != "k6") | .Health' 2>/dev/null | sort -u || echo "unknown")
  if ! echo "$all_health" | grep -qv "healthy"; then
    break
  fi
  sleep 3
  elapsed=$((elapsed + 3))
  echo "  ... ${elapsed}s"
done
pass "Infrastructure healthy (${elapsed}s)"

header "Submitting ${JOB_COUNT} autoscaled jobs"
JOB_IDS=()
SERVICE_NAMES=()
JOB_MAX_COUNTS=()
JOB_MIN_COUNTS=()
RESULTS_DIR="$SCRIPT_DIR/.autoscaling-stress-results/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RESULTS_DIR"
info "Request results dir: $RESULTS_DIR"
info "Setup concurrency: $SETUP_CONCURRENCY"
for idx in $(seq 1 "$JOB_COUNT"); do
  job_id="autoscale-many-${idx}"
  service_name="real-many-${idx}"
  max_count=$(max_count_for_index "$idx")
  JOB_IDS+=("$job_id")
  SERVICE_NAMES+=("$service_name")
  JOB_MAX_COUNTS+=("$max_count")
  JOB_MIN_COUNTS+=(1)
done

batch_pids=()
for idx in $(seq 1 "$JOB_COUNT"); do
  prepare_job "$idx" >"$RESULTS_DIR/setup-${idx}.log" 2>&1 &
  batch_pids+=("$!")

  if [ "${#batch_pids[@]}" -ge "$SETUP_CONCURRENCY" ]; then
    for pid in "${batch_pids[@]}"; do
      if ! wait "$pid"; then
        fail "A job setup worker failed; see $RESULTS_DIR/setup-*.log"
      fi
    done
    batch_pids=()
  fi
done

if [ "${#batch_pids[@]}" -gt 0 ]; then
  for pid in "${batch_pids[@]}"; do
    if ! wait "$pid"; then
      fail "A job setup worker failed; see $RESULTS_DIR/setup-*.log"
    fi
  done
fi

for idx in $(seq 1 "$JOB_COUNT"); do
  log_file="$RESULTS_DIR/setup-${idx}.log"
  [ -f "$log_file" ] && tail -3 "$log_file"
done
pass "Submitted and zeroed ${JOB_COUNT} jobs"

header "Concurrent pressure"
for idx in "${!SERVICE_NAMES[@]}"; do
  service_name="${SERVICE_NAMES[$idx]}"
  start_pressure "$service_name" "$DURATION_SECS" "$RESULTS_DIR/${service_name}.txt" "$((idx + 1))"
done

if $REQUIRE_CAPS; then
  wait_for_all_reached_caps "$CAP_WAIT_SECS"
  pass "All jobs reached their per-job caps without exceeding them"
else
  observe_scale_for "$CAP_WAIT_SECS"
  summarize_scale_results
  pass "Observed scale behavior without cap violations"
fi

header "Waiting for pressure to finish"
for pid in ${PRESSURE_PIDS:-}; do
  wait "$pid"
done
PRESSURE_PIDS=""
pass "Pressure finished"
summarize_request_results

header "Scale down to zero"
wait_for_all_saw_min_before_zero "$ZERO_WAIT_SECS"
pass "All jobs returned to zero"

header "Observability checks"
curl -fsS "$NSCALE_ADMIN/metrics" | grep 'nscale_autoscale_decisions_total' >/dev/null
curl -fsS "$NSCALE_ADMIN/admin/autoscaling" | jq -e --argjson expected "$JOB_COUNT" '(.jobs | length) >= $expected' >/dev/null
pass "Autoscaling metrics and admin overview are available"

header "Done"
pass "Autoscaling many-job stress completed for ${JOB_COUNT} jobs"
