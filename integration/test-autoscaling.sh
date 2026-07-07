#!/usr/bin/env bash
# Integration test for nscale per-job autoscaling.
#
# Prerequisites: docker, docker compose, curl, jq, openssl.
# This suite is intentionally opt-in because it drives load through the full
# Nomad/Consul/Traefik/nscale stack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ECHO_JOB_FILE="$SCRIPT_DIR/jobs/autoscale-echo.nomad"
SLOW_JOB_FILE="$SCRIPT_DIR/jobs/autoscale-slow.nomad"
TRAEFIK_CERT_SCRIPT="$SCRIPT_DIR/traefik/certs/generate.sh"

NOMAD_ADDR="http://localhost:4646"
NSCALE_PROXY="http://localhost:80"
NSCALE_ADMIN="http://localhost:9090"

ECHO_JOB_ID="autoscale-echo"
SLOW_JOB_ID="autoscale-slow"
GROUP="main"

INFRA_TIMEOUT=120
WAKE_TIMEOUT=90
AUTOSCALE_TIMEOUT=180
SCALEDOWN_TIMEOUT=90

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

cleanup() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        info "Autoscaling integration failed; collecting diagnostics..."
        docker compose -f "$COMPOSE_FILE" logs nscale traefik nomad || true
        info "nscale metrics snapshot:"
        curl -fsS "$NSCALE_ADMIN/metrics" || true
        info "Traefik request metric snapshot:"
        docker compose -f "$COMPOSE_FILE" exec -T traefik wget -qO- http://127.0.0.1:8082/metrics \
            | grep -E 'traefik_(service|router)_requests_total' || true
        info "Nomad autoscale-echo job snapshot:"
        curl -fsS "$NOMAD_ADDR/v1/job/${ECHO_JOB_ID}" | jq . || true
    fi

    info "Cleaning up autoscaling integration stack..."
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

wait_for_job_running() {
    local job_id="$1"
    local timeout="${2:-$WAKE_TIMEOUT}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local count running
        count=$(nomad_count "$job_id" 2>/dev/null || echo 0)
        running=$(running_allocs "$job_id" 2>/dev/null || echo 0)
        if [ "$count" -gt 0 ] && [ "$running" -gt 0 ]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    fail "Job ${job_id} did not become running within ${timeout}s"
    curl -s "$NOMAD_ADDR/v1/job/${job_id}/allocations" | jq . || true
    exit 1
}

wait_for_job_missing() {
    local job_id="$1"
    local timeout="${2:-60}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "$NOMAD_ADDR/v1/job/${job_id}")
        if [ "$code" = "404" ]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    fail "Job ${job_id} was not removed within ${timeout}s"
    exit 1
}

wait_for_job_count_at_least() {
    local job_id="$1"
    local min_count="$2"
    local timeout="${3:-$AUTOSCALE_TIMEOUT}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local count
        count=$(nomad_count "$job_id")
        echo "  ... ${elapsed}s ${job_id} count=${count}, expecting >= ${min_count}"
        if [ "$count" -ge "$min_count" ]; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    fail "Job ${job_id} did not reach count >= ${min_count} within ${timeout}s"
    curl -s "$NOMAD_ADDR/v1/job/${job_id}" | jq . || true
    docker compose -f "$COMPOSE_FILE" logs nscale
    exit 1
}

wait_for_job_count_exact() {
    local job_id="$1"
    local expected="$2"
    local timeout="${3:-$AUTOSCALE_TIMEOUT}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local count
        count=$(nomad_count "$job_id")
        echo "  ... ${elapsed}s ${job_id} count=${count}, expecting ${expected}"
        if [ "$count" -eq "$expected" ]; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    fail "Job ${job_id} did not reach count ${expected} within ${timeout}s"
    curl -s "$NOMAD_ADDR/v1/job/${job_id}" | jq . || true
    docker compose -f "$COMPOSE_FILE" logs nscale
    exit 1
}

assert_job_count_at_most() {
    local job_id="$1"
    local max_count="$2"
    local count
    count=$(nomad_count "$job_id")

    if [ "$count" -gt "$max_count" ]; then
        fail "Job ${job_id} exceeded max_count=${max_count}; actual=${count}"
        docker compose -f "$COMPOSE_FILE" logs nscale
        exit 1
    fi
}

submit_autoscale_job() {
    local job_file="$1"
    local service_name="$2"
    local policy_json="$3"
    local variables
    variables=$(cat <<EOF
service_name = "${service_name}"
host_name = "${service_name}.localhost"
EOF
)

    local payload
    payload=$(jq -n \
        --rawfile hcl "$job_file" \
        --arg variables "$variables" \
        --argjson autoscaling "$policy_json" \
        '{hcl: $hcl, variables: $variables, autoscaling: $autoscaling}')

    curl -sS -w "\n%{http_code}" -X POST "$NSCALE_ADMIN/admin/jobs" \
        -H "Content-Type: application/json" \
        -d "$payload"
}

submit_expect_created() {
    local job_file="$1"
    local service_name="$2"
    local policy_json="$3"
    local response code body

    response=$(submit_autoscale_job "$job_file" "$service_name" "$policy_json")
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
        fail "Autoscale policy was not returned in managed service registration"
        echo "$body" | jq . || echo "$body"
        exit 1
    fi
}

purge_job() {
    local job_id="$1"
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$NSCALE_ADMIN/admin/jobs/${job_id}?force=true")
    if [[ "$code" =~ ^2 ]] || [ "$code" = "404" ]; then
        wait_for_job_missing "$job_id" 60 || true
        return 0
    fi

    fail "Failed to purge ${job_id}: HTTP ${code}"
    exit 1
}

run_k6_autoscale() {
    local service_name="$1"
    local high_rate="$2"
    local high_duration="$3"
    local cooldown_duration="${4:-10s}"
    local request_path="${5:-/cgi-bin/slow?delay=1}"

    docker compose -f "$COMPOSE_FILE" --profile stress run --rm \
        -e NSCALE_SERVICE_NAME="$service_name" \
        -e NSCALE_TRAEFIK_URL="http://traefik:80" \
        -e NSCALE_REQUEST_PATH="$request_path" \
        -e NSCALE_AUTOSCALE_LOW_RATE=1 \
        -e NSCALE_AUTOSCALE_HIGH_RATE="$high_rate" \
        -e NSCALE_AUTOSCALE_LOW_DURATION=10s \
        -e NSCALE_AUTOSCALE_HIGH_DURATION="$high_duration" \
        -e NSCALE_AUTOSCALE_COOLDOWN_DURATION="$cooldown_duration" \
        k6 run /scripts/autoscale-variable-traffic.js
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

assert_nscale_metrics() {
    if curl -fsS "$NSCALE_ADMIN/metrics" | grep 'nscale_proxy_requests_total' >/dev/null; then
        pass "nscale /metrics exposes proxy request counters"
    else
        fail "nscale /metrics does not expose proxy request counters"
        curl -fsS "$NSCALE_ADMIN/metrics" || true
        exit 1
    fi
}

dump_autoscale_evidence() {
    local service_name="$1"
    info "Autoscale evidence for ${service_name}: Nomad count=$(nomad_count "$ECHO_JOB_ID" 2>/dev/null || echo unknown)"
    info "Traefik request counters for ${service_name}:"
    traefik_metrics | grep -E 'traefik_(service|router)_requests_total' | grep "$service_name" || true
    info "Recent nscale autoscale logs:"
    docker compose -f "$COMPOSE_FILE" logs --tail=200 nscale | grep -Ei 'autoscale|autoscaling|scaled|scale-to-zero|traffic probe|metric' || true
}

warm_service() {
    local service_name="$1"
    local response code body
    response=$(request_host_path "$service_name" / "$WAKE_TIMEOUT")
    code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    if [ "$code" != "200" ]; then
        fail "Warm request failed for ${service_name}: HTTP ${code} — ${body}"
        docker compose -f "$COMPOSE_FILE" logs nscale traefik
        exit 1
    fi
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

info "Checking invalid autoscaling policies are rejected..."
INVALID_RESP=$(submit_autoscale_job "$ECHO_JOB_FILE" autoscale-invalid '{"target_requests_per_second_per_instance":1.0}')
INVALID_CODE=$(echo "$INVALID_RESP" | tail -1)
if [ "$INVALID_CODE" != "400" ]; then
    if [ "$INVALID_CODE" != "422" ]; then
        fail "Expected missing max_count policy to be rejected, got HTTP ${INVALID_CODE}"
        echo "$INVALID_RESP"
        exit 1
    fi
fi

INVALID_RESP=$(submit_autoscale_job "$ECHO_JOB_FILE" autoscale-invalid '{"min_count":2,"max_count":1,"target_requests_per_second_per_instance":1.0}')
INVALID_CODE=$(echo "$INVALID_RESP" | tail -1)
if [ "$INVALID_CODE" != "400" ]; then
    fail "Expected invalid caps policy to return 400, got HTTP ${INVALID_CODE}"
    echo "$INVALID_RESP"
    exit 1
fi
pass "Invalid policies are rejected"

info "Scenario 1: request-based scale-up from Traefik metrics..."
purge_job "$ECHO_JOB_ID" || true
submit_expect_created "$ECHO_JOB_FILE" autoscale-rps '{"max_count":3,"min_count":1,"scale_to_zero":true,"scale_up_step":2,"scale_down_step":1,"cooldown_secs":20,"decision_window_secs":30,"target_requests_per_second_per_instance":1.0}'
wait_for_job_running "$ECHO_JOB_ID"
wait_for_job_count_exact "$ECHO_JOB_ID" 1 60
warm_service autoscale-rps
run_k6_autoscale autoscale-rps 12 75s 10s
dump_autoscale_evidence autoscale-rps
wait_for_job_count_at_least "$ECHO_JOB_ID" 2 120
assert_job_count_at_most "$ECHO_JOB_ID" 3
assert_traefik_has_requests autoscale-rps
assert_nscale_metrics
pass "Request-based autoscaling increased count within cap"

info "Scenario 2: max_count cap under heavier pressure..."
purge_job "$ECHO_JOB_ID"
submit_expect_created "$ECHO_JOB_FILE" autoscale-cap '{"max_count":2,"min_count":1,"scale_to_zero":true,"scale_up_step":5,"scale_down_step":1,"cooldown_secs":20,"decision_window_secs":30,"target_requests_per_second_per_instance":0.5}'
wait_for_job_running "$ECHO_JOB_ID"
warm_service autoscale-cap
run_k6_autoscale autoscale-cap 20 75s 10s
dump_autoscale_evidence autoscale-cap
wait_for_job_count_exact "$ECHO_JOB_ID" 2 120
assert_job_count_at_most "$ECHO_JOB_ID" 2
pass "Autoscaling respects max_count under pressure"

info "Scenario 3: variable traffic scales up then down to nonzero count..."
purge_job "$ECHO_JOB_ID"
submit_expect_created "$ECHO_JOB_FILE" autoscale-variable '{"max_count":4,"min_count":1,"scale_to_zero":false,"scale_up_step":2,"scale_down_step":1,"cooldown_secs":15,"decision_window_secs":20,"target_requests_per_second_per_instance":2.0}'
wait_for_job_running "$ECHO_JOB_ID"
warm_service autoscale-variable
run_k6_autoscale autoscale-variable 14 80s 10s
dump_autoscale_evidence autoscale-variable
wait_for_job_count_at_least "$ECHO_JOB_ID" 2 120
wait_for_job_count_exact "$ECHO_JOB_ID" 1 150
pass "Variable traffic caused scale-up and nonzero scale-down"

info "Scenario 4: default scale_to_zero=true still allows idle dormancy..."
purge_job "$ECHO_JOB_ID"
submit_expect_created "$ECHO_JOB_FILE" autoscale-zero '{"max_count":3,"min_count":1,"cooldown_secs":20,"decision_window_secs":30,"target_requests_per_second_per_instance":1.0}'
wait_for_job_running "$ECHO_JOB_ID"
warm_service autoscale-zero
wait_for_job_count_exact "$ECHO_JOB_ID" 0 "$SCALEDOWN_TIMEOUT"
warm_service autoscale-zero
wait_for_job_count_at_least "$ECHO_JOB_ID" 1 60
pass "Default scale_to_zero=true scales idle job to zero and wakes again"

info "Scenario 5: scale_to_zero=false keeps idle autoscaled jobs warm..."
purge_job "$ECHO_JOB_ID"
submit_expect_created "$ECHO_JOB_FILE" autoscale-nozero '{"max_count":2,"min_count":1,"scale_to_zero":false,"cooldown_secs":20,"decision_window_secs":30,"target_requests_per_second_per_instance":1.0}'
wait_for_job_running "$ECHO_JOB_ID"
warm_service autoscale-nozero
sleep "$SCALEDOWN_TIMEOUT"
NOZERO_COUNT=$(nomad_count "$ECHO_JOB_ID")
if [ "$NOZERO_COUNT" -lt 1 ]; then
    fail "scale_to_zero=false job became dormant"
    exit 1
fi
pass "scale_to_zero=false preserved nonzero count after idle window"

info "Scenario 6: nscale-native latency-driven scale-up..."
purge_job "$SLOW_JOB_ID" || true
submit_expect_created "$SLOW_JOB_FILE" autoscale-slow '{"max_count":3,"min_count":1,"scale_to_zero":true,"scale_up_step":1,"scale_down_step":1,"cooldown_secs":20,"decision_window_secs":30,"target_p95_latency_ms":100.0}'
wait_for_job_running "$SLOW_JOB_ID"
warm_service autoscale-slow
end=$((SECONDS + 75))
while [ "$SECONDS" -lt "$end" ]; do
    request_host_path autoscale-slow '/cgi-bin/slow?delay=1' 10 >/dev/null || true
done
curl -fsS "$NSCALE_ADMIN/metrics" | grep 'nscale_proxy_request_duration_seconds' >/dev/null
wait_for_job_count_at_least "$SLOW_JOB_ID" 2 120
pass "nscale-native latency metrics drove autoscale scale-up"

echo ""
echo "========================================"
echo -e "${GREEN}  Autoscaling integration test completed!${NC}"
echo "========================================"
echo ""
echo "Verified:"
echo "  1. Per-job autoscaling policy validation"
echo "  2. Traefik request-rate scale-up"
echo "  3. max_count cap enforcement under pressure"
echo "  4. Variable traffic scale-up and nonzero scale-down"
echo "  5. Default scale_to_zero=true idle dormancy and wake"
echo "  6. scale_to_zero=false warm minimum behavior"
echo "  7. nscale-native latency-driven autoscaling"
