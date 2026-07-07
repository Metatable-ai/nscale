#!/usr/bin/env bash
# Opt-in Prometheus-backed autoscaling integration test for nscale.
#
# This starts the normal integration stack plus Prometheus, configures nscale
# with NSCALE_PROMETHEUS__URL, verifies Prometheus has Traefik and nscale
# samples, and checks that request-rate autoscaling still scales up and down.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
PROM_COMPOSE_FILE="$SCRIPT_DIR/docker-compose.prometheus.yml"
ECHO_JOB_FILE="$SCRIPT_DIR/jobs/autoscale-echo.nomad"
TRAEFIK_CERT_SCRIPT="$SCRIPT_DIR/traefik/certs/generate.sh"

NOMAD_ADDR="http://localhost:4646"
NSCALE_PROXY="http://localhost:80"
NSCALE_ADMIN="http://localhost:9090"
PROMETHEUS_URL="http://localhost:19090"

JOB_ID="autoscale-echo"
GROUP="main"
SERVICE_NAME="prom-autoscale"

INFRA_TIMEOUT=150
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

dc() {
    docker compose -f "$COMPOSE_FILE" -f "$PROM_COMPOSE_FILE" "$@"
}

cleanup() {
    local exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        info "Prometheus autoscaling integration failed; collecting diagnostics..."
        dc logs nscale traefik prometheus nomad || true
        info "nscale metrics snapshot:"
        curl -fsS "$NSCALE_ADMIN/metrics" || true
        info "Prometheus Traefik query:"
        prometheus_query 'sum(rate(traefik_router_requests_total[30s])) or vector(0)' || true
        info "Prometheus nscale query:"
        prometheus_query 'sum(rate(nscale_proxy_requests_total[30s])) or vector(0)' || true
        info "Nomad job snapshot:"
        curl -fsS "$NOMAD_ADDR/v1/job/${JOB_ID}" | jq . || true
    fi

    info "Cleaning up Prometheus autoscaling stack..."
    cd "$SCRIPT_DIR"
    dc down -v --remove-orphans 2>/dev/null || true
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
    dc logs nscale nomad
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
    dc logs nscale nomad
    exit 1
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
}

submit_autoscale_job() {
    local service_name="$1"
    local policy_json="$2"
    local variables payload response code body

    variables=$(cat <<EOF
service_name = "${service_name}"
host_name = "${service_name}.localhost"
EOF
)

    payload=$(jq -n \
        --rawfile hcl "$ECHO_JOB_FILE" \
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

force_scale_to_zero() {
    local job_id="$1"
    local timeout="${2:-90}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local response code body
        response=$(curl -sS -w "\n%{http_code}" -X POST "$NOMAD_ADDR/v1/job/${job_id}/scale" \
            -H "Content-Type: application/json" \
            -d "{\"Count\":0,\"Target\":{\"Group\":\"${GROUP}\"},\"Message\":\"prometheus autoscaling test: start from zero\"}")
        code=$(echo "$response" | tail -1)
        body=$(echo "$response" | sed '$d')
        if [[ "$code" =~ ^2 ]]; then
            wait_for_job_count_exact "$job_id" 0 "$SCALE_ZERO_TIMEOUT"
            return 0
        fi

        if echo "$body" | grep -qi 'active deployment'; then
            sleep 3
            elapsed=$((elapsed + 3))
            echo "  ... waiting (${elapsed}s) for ${job_id} deployment to allow scale-to-zero"
            continue
        fi

        fail "Failed to scale ${job_id} to zero: HTTP ${code}"
        echo "$response"
        exit 1
    done

    fail "Failed to scale ${job_id} to zero within ${timeout}s due to active deployment"
    curl -s "$NOMAD_ADDR/v1/job/${job_id}/deployments" | jq . || true
    exit 1
}

warm_service() {
    local service_name="$1"
    local response code body
    response=$(request_host_path "$service_name" / "$WAKE_TIMEOUT")
    code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    if [ "$code" != "200" ]; then
        fail "Warm request failed for ${service_name}: HTTP ${code} — ${body}"
        dc logs nscale traefik
        exit 1
    fi
}

run_k6_autoscale() {
    local service_name="$1"
    local rate="$2"
    local duration="$3"

    dc --profile stress run --rm \
        -e NSCALE_SERVICE_NAME="$service_name" \
        -e NSCALE_TRAEFIK_URL="http://traefik:80" \
        -e NSCALE_REQUEST_PATH=/ \
        -e NSCALE_AUTOSCALE_LOW_RATE=1 \
        -e NSCALE_AUTOSCALE_HIGH_RATE="$rate" \
        -e NSCALE_AUTOSCALE_LOW_DURATION=10s \
        -e NSCALE_AUTOSCALE_HIGH_DURATION="$duration" \
        -e NSCALE_AUTOSCALE_COOLDOWN_DURATION=10s \
        k6 run /scripts/autoscale-variable-traffic.js
}

prometheus_query() {
    local query="$1"
    curl -fsS --get "$PROMETHEUS_URL/api/v1/query" --data-urlencode "query=${query}"
}

wait_for_prometheus_vector_value() {
    local description="$1"
    local query="$2"
    local timeout="${3:-60}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        local value
        value=$(prometheus_query "$query" \
            | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true)
        if [ -n "$value" ] && awk "BEGIN { exit !($value > 0) }"; then
            pass "Prometheus has ${description}: ${value}"
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
        echo "  ... waiting (${elapsed}s) for Prometheus ${description}"
    done

    fail "Prometheus did not expose ${description} within ${timeout}s"
    prometheus_query "$query" | jq . || true
    exit 1
}

assert_count_never_exceeds_for() {
    local job_id="$1"
    local max_count="$2"
    local duration="$3"
    local elapsed=0

    while [ "$elapsed" -lt "$duration" ]; do
        local count
        count=$(nomad_count "$job_id" 2>/dev/null || echo 0)
        if [ "$count" -gt "$max_count" ]; then
            fail "${job_id} exceeded max_count=${max_count}; actual=${count}"
            dc logs nscale nomad
            exit 1
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
}

start_count_ceiling_monitor() {
    local job_id="$1"
    local max_count="$2"
    local duration="$3"

    assert_count_never_exceeds_for "$job_id" "$max_count" "$duration" &
    COUNT_MONITOR_PID=$!
}

trap cleanup EXIT

info "Checking prerequisites..."
for cmd in docker curl jq openssl awk; do
    if ! command -v "$cmd" &>/dev/null; then
        fail "Required command '$cmd' not found"
        exit 1
    fi
done
pass "Prerequisites OK"

info "Ensuring local Traefik TLS certificates exist..."
bash "$TRAEFIK_CERT_SCRIPT"
pass "Traefik TLS certificates ready"

info "Starting infrastructure with Prometheus via docker compose..."
cd "$SCRIPT_DIR"
dc up -d --build

info "Waiting for infrastructure health..."
elapsed=0
while true; do
    if [ "$elapsed" -ge "$INFRA_TIMEOUT" ]; then
        fail "Infrastructure did not start within ${INFRA_TIMEOUT}s"
        dc logs
        exit 1
    fi

    redis_ok=$(dc ps --format json | jq -r 'select(.Service=="redis") | .Health' 2>/dev/null || echo unknown)
    consul_ok=$(dc ps --format json | jq -r 'select(.Service=="consul") | .Health' 2>/dev/null || echo unknown)
    nomad_ok=$(dc ps --format json | jq -r 'select(.Service=="nomad") | .Health' 2>/dev/null || echo unknown)
    nscale_ok=$(dc ps --format json | jq -r 'select(.Service=="nscale") | .Health' 2>/dev/null || echo unknown)
    traefik_ok=$(dc ps --format json | jq -r 'select(.Service=="traefik") | .Health' 2>/dev/null || echo unknown)
    prometheus_ok=$(dc ps --format json | jq -r 'select(.Service=="prometheus") | .Health' 2>/dev/null || echo unknown)

    if [[ "$redis_ok" == "healthy" && "$consul_ok" == "healthy" && "$nomad_ok" == "healthy" && "$nscale_ok" == "healthy" && "$traefik_ok" == "healthy" && "$prometheus_ok" == "healthy" ]]; then
        break
    fi

    sleep 3
    elapsed=$((elapsed + 3))
    echo "  ... waiting (${elapsed}s) redis=$redis_ok consul=$consul_ok nomad=$nomad_ok nscale=$nscale_ok traefik=$traefik_ok prometheus=$prometheus_ok"
done
pass "All services healthy (${elapsed}s)"

curl -fsS "$NSCALE_ADMIN/metrics" >/dev/null
curl -fsS "$PROMETHEUS_URL/-/ready" >/dev/null
pass "nscale and Prometheus endpoints are available"

info "Checking nscale started with Prometheus autoscaling provider..."
if dc logs nscale | grep 'Prometheus autoscaling metrics enabled' >/dev/null; then
    pass "nscale Prometheus autoscaling provider is enabled"
else
    fail "nscale did not log Prometheus autoscaling provider enablement"
    dc logs nscale
    exit 1
fi

POLICY='{"max_count":3,"min_count":1,"scale_to_zero":true,"scale_up_step":5,"scale_down_step":1,"cooldown_secs":15,"decision_window_secs":20,"target_requests_per_second_per_instance":1.0}'

info "Submitting autoscaled job and forcing cold start path..."
purge_job "$JOB_ID" || true
submit_autoscale_job "$SERVICE_NAME" "$POLICY"
wait_for_job_running "$JOB_ID"
wait_for_job_count_exact "$JOB_ID" 1 60
wait_for_deployment_complete "$JOB_ID"
force_scale_to_zero "$JOB_ID"

info "Driving traffic through Traefik while Prometheus scrapes metrics..."
start_count_ceiling_monitor "$JOB_ID" 3 140
run_k6_autoscale "$SERVICE_NAME" 14 90s
wait "$COUNT_MONITOR_PID"

wait_for_prometheus_vector_value \
    "Traefik request rate for ${SERVICE_NAME}" \
    "(sum(rate(traefik_router_requests_total{router=~\"${SERVICE_NAME}@consulcatalog\"}[30s])) or vector(0)) + (sum(rate(traefik_service_requests_total{service=~\"${SERVICE_NAME}@consulcatalog\"}[30s])) or vector(0))" \
    90

wait_for_prometheus_vector_value \
    "nscale proxy request rate" \
    'sum(rate(nscale_proxy_requests_total[30s])) or vector(0)' \
    90

wait_for_job_count_at_least "$JOB_ID" 2 120
pass "Prometheus-backed request-rate autoscaling increased count within cap"

info "Waiting for traffic to drain and job to return to zero..."
wait_for_job_count_exact "$JOB_ID" 1 "$SCALE_ZERO_TIMEOUT"
wait_for_job_count_exact "$JOB_ID" 0 "$SCALE_ZERO_TIMEOUT"
pass "Prometheus-backed autoscaled job returned to zero"

echo ""
echo "========================================"
echo -e "${GREEN}  Prometheus autoscaling integration test completed!${NC}"
echo "========================================"
echo ""
echo "Verified:"
echo "  1. Prometheus service runs as opt-in compose override"
echo "  2. nscale starts with NSCALE_PROMETHEUS__URL configured"
echo "  3. Prometheus scrapes Traefik request metrics"
echo "  4. Prometheus scrapes nscale proxy metrics"
echo "  5. Autoscaling scales up within max_count and returns to zero"
