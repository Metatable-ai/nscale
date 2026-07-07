#!/usr/bin/env bash
# Real-world autoscaling lifecycle test for nscale.
#
# Verifies operational behavior under live traffic:
#   fast job: 0 -> wake -> max_count=2 -> 0
#   slow job: 0 -> wake -> max_count=3 -> 0
#   fast + slow concurrently: both respect caps and return to zero

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ECHO_JOB_FILE="$SCRIPT_DIR/jobs/autoscale-echo.nomad"
SLOW_JOB_FILE="$SCRIPT_DIR/jobs/autoscale-slow.nomad"
TRAEFIK_CERT_SCRIPT="$SCRIPT_DIR/traefik/certs/generate.sh"

NOMAD_ADDR="http://localhost:4646"
NSCALE_PROXY="http://localhost:80"
NSCALE_ADMIN="http://localhost:9090"

FAST_JOB_ID="autoscale-echo"
SLOW_JOB_ID="autoscale-slow"
GROUP="main"

INFRA_TIMEOUT=120
WAKE_TIMEOUT=90
SCALE_UP_TIMEOUT=180
SCALE_ZERO_TIMEOUT=240

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

FAST_K6_PID=""
SLOW_K6_PID=""
FAST_K6_OUT=""
SLOW_K6_OUT=""

cleanup() {
    local exit_code=$?

    for pid in ${FAST_K6_PID:-} ${SLOW_K6_PID:-}; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done

    if [ "$exit_code" -ne 0 ]; then
        info "Real-world autoscaling test failed; collecting diagnostics..."
        docker compose -f "$COMPOSE_FILE" logs nscale traefik nomad || true
        info "Fast k6 output:"
        [ -n "${FAST_K6_OUT:-}" ] && [ -f "$FAST_K6_OUT" ] && cat "$FAST_K6_OUT" || true
        info "Slow k6 output:"
        [ -n "${SLOW_K6_OUT:-}" ] && [ -f "$SLOW_K6_OUT" ] && cat "$SLOW_K6_OUT" || true
        info "nscale metrics snapshot:"
        curl -fsS "$NSCALE_ADMIN/metrics" || true
        info "Traefik request metric snapshot:"
        docker compose -f "$COMPOSE_FILE" exec -T traefik wget -qO- http://127.0.0.1:8082/metrics \
            | grep -E 'traefik_(service|router)_requests_total' || true
        info "Nomad fast job snapshot:"
        curl -fsS "$NOMAD_ADDR/v1/job/${FAST_JOB_ID}" | jq . || true
        info "Nomad slow job snapshot:"
        curl -fsS "$NOMAD_ADDR/v1/job/${SLOW_JOB_ID}" | jq . || true
    fi

    rm -f "${FAST_K6_OUT:-}" "${SLOW_K6_OUT:-}" 2>/dev/null || true

    info "Cleaning up real-world autoscaling stack..."
    cd "$SCRIPT_DIR"
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    docker network rm nscale-net 2>/dev/null || true
}

request_host_path() {
    local service_name="$1"
    local path="${2:-/}"
    local max_time="${3:-30}"
    curl -s -w "\n%{http_code}" \
        -H "Host: ${service_name}.localhost" \
        "${NSCALE_PROXY}${path}" \
        --max-time "$max_time"
}

nomad_count() {
    local job_id="$1"
    curl -s "$NOMAD_ADDR/v1/job/${job_id}" | jq '.TaskGroups[0].Count'
}

running_allocs() {
    local job_id="$1"
    curl -s "$NOMAD_ADDR/v1/job/${job_id}/allocations" \
        | jq '[.[] | select(.ClientStatus == "running")] | length'
}

wait_for_job_count_exact() {
    local job_id="$1"
    local expected="$2"
    local timeout="${3:-$SCALE_UP_TIMEOUT}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local count
        count=$(nomad_count "$job_id" 2>/dev/null || echo 0)
        echo "  ... ${elapsed}s ${job_id} count=${count}, expecting ${expected}"
        if [ "$count" -eq "$expected" ]; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    fail "Job ${job_id} did not reach count ${expected} within ${timeout}s"
    curl -s "$NOMAD_ADDR/v1/job/${job_id}" | jq . || true
    docker compose -f "$COMPOSE_FILE" logs nscale nomad
    exit 1
}

wait_for_job_count_at_least() {
    local job_id="$1"
    local expected="$2"
    local timeout="${3:-$SCALE_UP_TIMEOUT}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local count
        count=$(nomad_count "$job_id" 2>/dev/null || echo 0)
        echo "  ... ${elapsed}s ${job_id} count=${count}, expecting >= ${expected}"
        if [ "$count" -ge "$expected" ]; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    fail "Job ${job_id} did not reach count >= ${expected} within ${timeout}s"
    curl -s "$NOMAD_ADDR/v1/job/${job_id}" | jq . || true
    docker compose -f "$COMPOSE_FILE" logs nscale nomad
    exit 1
}

wait_for_deployment_complete() {
    local job_id="$1"
    local timeout="${2:-90}"
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
    curl -s "$NOMAD_ADDR/v1/job/${job_id}/deployments" | jq . || true
    exit 1
}

assert_job_count_at_most() {
    local job_id="$1"
    local max_count="$2"
    local count
    count=$(nomad_count "$job_id")

    if [ "$count" -gt "$max_count" ]; then
        fail "${job_id} exceeded max_count=${max_count}; actual=${count}"
        docker compose -f "$COMPOSE_FILE" logs nscale nomad
        exit 1
    fi
}

assert_count_never_exceeds_for() {
    local job_id="$1"
    local max_count="$2"
    local duration="$3"
    local elapsed=0

    while [ "$elapsed" -lt "$duration" ]; do
        assert_job_count_at_most "$job_id" "$max_count"
        local count
        count=$(nomad_count "$job_id")
        echo "  ... ${elapsed}s ${job_id} count=${count}, cap=${max_count}"
        sleep 5
        elapsed=$((elapsed + 5))
    done
}

submit_autoscale_job() {
    local job_file="$1"
    local service_name="$2"
    local policy_json="$3"
    local variables payload response code body

    variables=$(cat <<EOF
service_name = "${service_name}"
host_name = "${service_name}.localhost"
EOF
)

    payload=$(jq -n \
        --rawfile hcl "$job_file" \
        --arg variables "$variables" \
        --argjson autoscaling "$policy_json" \
        '{hcl: $hcl, variables: $variables, autoscaling: $autoscaling}')

    response=$(curl -sS -w "\n%{http_code}" -X POST "$NSCALE_ADMIN/admin/jobs" \
        -H "Content-Type: application/json" \
        -d "$payload")
    code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [ "$code" != "201" ]; then
        fail "Autoscale job submission failed for ${service_name}: HTTP ${code}"
        echo "$body" | jq . || echo "$body"
        docker compose -f "$COMPOSE_FILE" logs nscale
        exit 1
    fi

    if ! echo "$body" | jq -e --arg service_name "$service_name" '
        (.managed_services | length) == 1 and
        .managed_services[0].service_name == $service_name and
        .managed_services[0].autoscaling.max_count != null
    ' >/dev/null; then
        fail "Autoscale policy missing in /admin/jobs response for ${service_name}"
        echo "$body" | jq . || echo "$body"
        exit 1
    fi
}


purge_job() {
    local job_id="$1"
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$NSCALE_ADMIN/admin/jobs/${job_id}?force=true")
    if [[ "$code" =~ ^2 ]] || [ "$code" = "404" ]; then
        return 0
    fi

    fail "Failed to purge ${job_id}: HTTP ${code}"
    exit 1
}

force_scale_to_zero() {
    local job_id="$1"
    local response code
    response=$(curl -sS -w "\n%{http_code}" -X POST "$NOMAD_ADDR/v1/job/${job_id}/scale" \
        -H "Content-Type: application/json" \
        -d "{\"Count\":0,\"Target\":{\"Group\":\"${GROUP}\"},\"Message\":\"real-world autoscaling test: start from zero\"}")
    code=$(echo "$response" | tail -1)
    if [[ ! "$code" =~ ^2 ]]; then
        fail "Failed to scale ${job_id} to zero: HTTP ${code}"
        echo "$response"
        exit 1
    fi
    wait_for_job_count_exact "$job_id" 0 "$SCALE_ZERO_TIMEOUT"
}

warm_service() {
    local service_name="$1"
    local path="${2:-/}"
    local response code body
    response=$(request_host_path "$service_name" "$path" "$WAKE_TIMEOUT")
    code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    if [ "$code" != "200" ]; then
        fail "Warm request failed for ${service_name}: HTTP ${code} — ${body}"
        docker compose -f "$COMPOSE_FILE" logs nscale traefik
        exit 1
    fi
}

start_k6_background() {
    local service_name="$1"
    local rate="$2"
    local duration="$3"
    local request_path="$4"
    local output_file="$5"

    docker compose -f "$COMPOSE_FILE" --profile stress run --rm \
        -e NSCALE_SERVICE_NAME="$service_name" \
        -e NSCALE_TRAEFIK_URL="http://traefik:80" \
        -e NSCALE_REQUEST_PATH="$request_path" \
        -e NSCALE_AUTOSCALE_LOW_RATE="$rate" \
        -e NSCALE_AUTOSCALE_HIGH_RATE="$rate" \
        -e NSCALE_AUTOSCALE_LOW_DURATION=5s \
        -e NSCALE_AUTOSCALE_HIGH_DURATION="$duration" \
        -e NSCALE_AUTOSCALE_COOLDOWN_DURATION=5s \
        k6 run /scripts/autoscale-variable-traffic.js >"$output_file" 2>&1 &

    LAST_K6_PID=$!
}


wait_for_k6_success() {
    local pid="$1"
    local output_file="$2"

    if ! wait "$pid"; then
        fail "k6 traffic run failed"
        cat "$output_file"
        exit 1
    fi

    if grep -Eq 'checks_failed\.*: [1-9]' "$output_file"; then
        fail "k6 reported failed checks"
        cat "$output_file"
        exit 1
    fi
}

traefik_metrics() {
    docker compose -f "$COMPOSE_FILE" exec -T traefik wget -qO- http://127.0.0.1:8082/metrics
}

assert_traefik_has_requests() {
    local service_name="$1"
    if traefik_metrics | grep -E 'traefik_(service|router)_requests_total' | grep -E "(service|router)=\"${service_name}@consulcatalog\"" >/dev/null; then
        pass "Traefik metrics include request counters for ${service_name}"
    else
        fail "Traefik metrics missing request counters for ${service_name}"
        traefik_metrics | grep -E 'traefik_(service|router)_requests_total' || true
        exit 1
    fi
}

dump_counts() {
    info "Counts: ${FAST_JOB_ID}=$(nomad_count "$FAST_JOB_ID" 2>/dev/null || echo missing), ${SLOW_JOB_ID}=$(nomad_count "$SLOW_JOB_ID" 2>/dev/null || echo missing)"
}

trap cleanup EXIT

info "Checking prerequisites..."
for cmd in docker curl jq openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        fail "Required command '$cmd' not found"
        exit 1
    fi
done
pass "Prerequisites OK"

info "Ensuring local Traefik TLS certificates exist..."
bash "$TRAEFIK_CERT_SCRIPT"
pass "Traefik TLS certificates ready"

info "Starting infrastructure via docker compose..."
cd "$SCRIPT_DIR"
docker compose -f "$COMPOSE_FILE" up -d --build

info "Waiting for infrastructure health..."
elapsed=0
while true; do
    if [ "$elapsed" -ge "$INFRA_TIMEOUT" ]; then
        fail "Infrastructure did not start within ${INFRA_TIMEOUT}s"
        docker compose -f "$COMPOSE_FILE" logs
        exit 1
    fi

    redis_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json | jq -r 'select(.Service=="redis") | .Health' 2>/dev/null || echo unknown)
    consul_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json | jq -r 'select(.Service=="consul") | .Health' 2>/dev/null || echo unknown)
    nomad_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json | jq -r 'select(.Service=="nomad") | .Health' 2>/dev/null || echo unknown)
    nscale_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json | jq -r 'select(.Service=="nscale") | .Health' 2>/dev/null || echo unknown)
    traefik_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json | jq -r 'select(.Service=="traefik") | .Health' 2>/dev/null || echo unknown)

    if [[ "$redis_ok" == "healthy" && "$consul_ok" == "healthy" && "$nomad_ok" == "healthy" && "$nscale_ok" == "healthy" && "$traefik_ok" == "healthy" ]]; then
        break
    fi

    sleep 3
    elapsed=$((elapsed + 3))
    echo "  ... waiting (${elapsed}s) redis=$redis_ok consul=$consul_ok nomad=$nomad_ok nscale=$nscale_ok traefik=$traefik_ok"
done
pass "All services healthy (${elapsed}s)"

curl -fsS "$NSCALE_ADMIN/metrics" >/dev/null
pass "nscale /metrics endpoint is available"

FAST_POLICY='{"max_count":2,"min_count":1,"scale_to_zero":true,"scale_up_step":1,"scale_down_step":1,"cooldown_secs":15,"decision_window_secs":20,"target_requests_per_second_per_instance":2.0}'
SLOW_POLICY='{"max_count":3,"min_count":1,"scale_to_zero":true,"scale_up_step":1,"scale_down_step":1,"cooldown_secs":15,"decision_window_secs":20,"target_requests_per_second_per_instance":1.0,"target_p95_latency_ms":250.0}'

info "Scenario 1: fast job lifecycle 0 → 2 → 0"
purge_job "$FAST_JOB_ID" || true
submit_autoscale_job "$ECHO_JOB_FILE" real-fast "$FAST_POLICY"
wait_for_job_count_at_least "$FAST_JOB_ID" 1 "$WAKE_TIMEOUT"
wait_for_deployment_complete "$FAST_JOB_ID"
force_scale_to_zero "$FAST_JOB_ID"
FAST_K6_OUT=$(mktemp)
start_k6_background real-fast 24 130s / "$FAST_K6_OUT"
FAST_K6_PID=$LAST_K6_PID
wait_for_job_count_at_least "$FAST_JOB_ID" 1 "$WAKE_TIMEOUT"
wait_for_job_count_exact "$FAST_JOB_ID" 2 "$SCALE_UP_TIMEOUT"
assert_count_never_exceeds_for "$FAST_JOB_ID" 2 30
wait_for_k6_success "$FAST_K6_PID" "$FAST_K6_OUT"
FAST_K6_PID=""
assert_traefik_has_requests real-fast
wait_for_job_count_exact "$FAST_JOB_ID" 1 "$SCALE_ZERO_TIMEOUT"
wait_for_job_count_exact "$FAST_JOB_ID" 0 "$SCALE_ZERO_TIMEOUT"
pass "Fast job scaled 0 → 2 → 0"

info "Scenario 2: slow job lifecycle 0 → 3 → 0"
purge_job "$SLOW_JOB_ID" || true
submit_autoscale_job "$SLOW_JOB_FILE" real-slow "$SLOW_POLICY"
wait_for_job_count_at_least "$SLOW_JOB_ID" 1 "$WAKE_TIMEOUT"
wait_for_deployment_complete "$SLOW_JOB_ID"
force_scale_to_zero "$SLOW_JOB_ID"
SLOW_K6_OUT=$(mktemp)
start_k6_background real-slow 15 160s '/cgi-bin/slow?delay=1' "$SLOW_K6_OUT"
SLOW_K6_PID=$LAST_K6_PID
wait_for_job_count_at_least "$SLOW_JOB_ID" 1 "$WAKE_TIMEOUT"
wait_for_job_count_exact "$SLOW_JOB_ID" 3 "$SCALE_UP_TIMEOUT"
assert_count_never_exceeds_for "$SLOW_JOB_ID" 3 30
wait_for_k6_success "$SLOW_K6_PID" "$SLOW_K6_OUT"
SLOW_K6_PID=""
assert_traefik_has_requests real-slow
wait_for_job_count_exact "$SLOW_JOB_ID" 2 "$SCALE_ZERO_TIMEOUT"
wait_for_job_count_exact "$SLOW_JOB_ID" 1 "$SCALE_ZERO_TIMEOUT"
wait_for_job_count_exact "$SLOW_JOB_ID" 0 "$SCALE_ZERO_TIMEOUT"
pass "Slow job scaled 0 → 3 → 0"

info "Scenario 3: concurrent fast and slow jobs respect caps and return to zero"
purge_job "$FAST_JOB_ID" || true
purge_job "$SLOW_JOB_ID" || true
submit_autoscale_job "$ECHO_JOB_FILE" real-fast-mixed "$FAST_POLICY"
submit_autoscale_job "$SLOW_JOB_FILE" real-slow-mixed "$SLOW_POLICY"
wait_for_job_count_at_least "$FAST_JOB_ID" 1 "$WAKE_TIMEOUT"
wait_for_job_count_at_least "$SLOW_JOB_ID" 1 "$WAKE_TIMEOUT"
wait_for_deployment_complete "$FAST_JOB_ID"
wait_for_deployment_complete "$SLOW_JOB_ID"
force_scale_to_zero "$FAST_JOB_ID"
force_scale_to_zero "$SLOW_JOB_ID"

FAST_K6_OUT=$(mktemp)
SLOW_K6_OUT=$(mktemp)
start_k6_background real-fast-mixed 24 150s / "$FAST_K6_OUT"
FAST_K6_PID=$LAST_K6_PID
start_k6_background real-slow-mixed 15 180s '/cgi-bin/slow?delay=1' "$SLOW_K6_OUT"
SLOW_K6_PID=$LAST_K6_PID

wait_for_job_count_exact "$FAST_JOB_ID" 2 "$SCALE_UP_TIMEOUT"
wait_for_job_count_exact "$SLOW_JOB_ID" 3 "$SCALE_UP_TIMEOUT"
assert_count_never_exceeds_for "$FAST_JOB_ID" 2 30
assert_count_never_exceeds_for "$SLOW_JOB_ID" 3 30
dump_counts

wait_for_k6_success "$FAST_K6_PID" "$FAST_K6_OUT"
FAST_K6_PID=""
wait_for_k6_success "$SLOW_K6_PID" "$SLOW_K6_OUT"
SLOW_K6_PID=""
assert_traefik_has_requests real-fast-mixed
assert_traefik_has_requests real-slow-mixed
wait_for_job_count_exact "$FAST_JOB_ID" 1 "$SCALE_ZERO_TIMEOUT"
wait_for_job_count_exact "$FAST_JOB_ID" 0 "$SCALE_ZERO_TIMEOUT"
wait_for_job_count_exact "$SLOW_JOB_ID" 2 "$SCALE_ZERO_TIMEOUT"
wait_for_job_count_exact "$SLOW_JOB_ID" 1 "$SCALE_ZERO_TIMEOUT"
wait_for_job_count_exact "$SLOW_JOB_ID" 0 "$SCALE_ZERO_TIMEOUT"
pass "Concurrent fast/slow jobs scaled to caps and returned to zero"

echo ""
echo "========================================"
echo -e "${GREEN}  Real-world autoscaling integration test completed!${NC}"
echo "========================================"
echo ""
echo "Verified:"
echo "  1. Fast job scaled 0 → 2 → 0"
echo "  2. Slow job scaled 0 → 3 → 0"
echo "  3. Concurrent fast/slow jobs respected caps and returned to zero"
