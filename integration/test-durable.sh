#!/usr/bin/env bash
# Integration test for nscale durable registry mode (etcd + Redis cache)
#
# Scenario:
#   1. Start infrastructure with etcd enabled for nscale durable registry
#   2. Submit a Nomad job through /admin/jobs
#   3. Verify registrations exist in both Redis and etcd
#   4. Delete Redis registry hashes only
#   5. Verify a warm-path request succeeds via etcd fallback and repopulates Redis
#   6. Scale job to zero, delete Redis registry hashes again
#   7. Verify a cold-start request succeeds via etcd fallback and repopulates Redis

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_BASE="$SCRIPT_DIR/docker-compose.yml"
COMPOSE_DURABLE="$SCRIPT_DIR/docker-compose.durable.yml"
JOB_FILE="$SCRIPT_DIR/jobs/echo-submit.nomad"
TRAEFIK_CERT_SCRIPT="$SCRIPT_DIR/traefik/certs/generate.sh"
COMPOSE_ARGS=(-f "$COMPOSE_BASE" -f "$COMPOSE_DURABLE")

NOMAD_ADDR="http://localhost:4646"
CONSUL_ADDR="http://localhost:8500"
NSCALE_PROXY="http://localhost:80"
NSCALE_ADMIN="http://localhost:9090"
HTTPS_RESOLVE_ADDR="${HTTPS_RESOLVE_ADDR:-127.0.0.1}"
ETCD_PREFIX="${ETCD_PREFIX:-/nscale/registrations}"

JOB_ID="echo-submit-job"
SERVICE_NAME="${SERVICE_NAME:-echo-s2z}"
SERVICE_GROUP="${SERVICE_GROUP:-main}"
ROUTER_HOST="${ROUTER_HOST:-${SERVICE_NAME}.localhost}"
HOST_HEADER="${HOST_HEADER:-${ROUTER_HOST}}"
ETCD_JOB_KEY="${ETCD_PREFIX}/jobs/${JOB_ID}"
ETCD_SERVICE_KEY="${ETCD_PREFIX}/services/${SERVICE_NAME}"

INFRA_TIMEOUT=150
WAKE_TIMEOUT=60

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

dc() {
    docker compose "${COMPOSE_ARGS[@]}" "$@"
}

request_https() {
    local max_time="${1:-30}"
    curl -k -s -w "\n%{http_code}" \
        --resolve "${HOST_HEADER}:443:${HTTPS_RESOLVE_ADDR}" \
        "https://${HOST_HEADER}/" \
        --max-time "$max_time"
}

build_submit_payload() {
    local variables
    variables=$(cat <<EOF
service_name = "${SERVICE_NAME}"
host_name = "${ROUTER_HOST}"
EOF
)

    jq -n --rawfile hcl "$JOB_FILE" --arg variables "$variables" '{hcl: $hcl, variables: $variables}'
}

assert_redis_registration_present() {
    local job_json service_json
    job_json=$(dc exec -T redis redis-cli --raw HGET nscale:jobs "$JOB_ID" | tr -d '\r')
    service_json=$(dc exec -T redis redis-cli --raw HGET nscale:jobs:services "$SERVICE_NAME" | tr -d '\r')

    if [[ -z "$job_json" || -z "$service_json" ]]; then
        fail "Expected Redis registry entries for job and service"
        exit 1
    fi

    if ! echo "$job_json" | jq -e --arg job_id "$JOB_ID" --arg service_name "$SERVICE_NAME" --arg group "$SERVICE_GROUP" '.job_id == $job_id and .service_name == $service_name and .nomad_group == $group' >/dev/null; then
        fail "Redis job registration payload is unexpected"
        echo "$job_json"
        exit 1
    fi

    if ! echo "$service_json" | jq -e --arg job_id "$JOB_ID" --arg service_name "$SERVICE_NAME" --arg group "$SERVICE_GROUP" '.job_id == $job_id and .service_name == $service_name and .nomad_group == $group' >/dev/null; then
        fail "Redis service registration payload is unexpected"
        echo "$service_json"
        exit 1
    fi
}

assert_etcd_registration_present() {
    local job_json service_json
    job_json=$(dc exec -T etcd /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 get "$ETCD_JOB_KEY" --print-value-only | tr -d '\r')
    service_json=$(dc exec -T etcd /usr/local/bin/etcdctl --endpoints=http://127.0.0.1:2379 get "$ETCD_SERVICE_KEY" --print-value-only | tr -d '\r')

    if [[ -z "$job_json" || -z "$service_json" ]]; then
        fail "Expected etcd registration entries for job and service"
        exit 1
    fi

    if ! echo "$job_json" | jq -e --arg job_id "$JOB_ID" --arg service_name "$SERVICE_NAME" --arg group "$SERVICE_GROUP" '.job_id == $job_id and .service_name == $service_name and .nomad_group == $group' >/dev/null; then
        fail "etcd job registration payload is unexpected"
        echo "$job_json"
        exit 1
    fi

    if ! echo "$service_json" | jq -e --arg job_id "$JOB_ID" --arg service_name "$SERVICE_NAME" --arg group "$SERVICE_GROUP" '.job_id == $job_id and .service_name == $service_name and .nomad_group == $group' >/dev/null; then
        fail "etcd service registration payload is unexpected"
        echo "$service_json"
        exit 1
    fi
}

clear_redis_registry_cache() {
    dc exec -T redis redis-cli DEL nscale:jobs nscale:jobs:services >/dev/null
}

assert_redis_registry_empty() {
    local job_count service_count
    job_count=$(dc exec -T redis redis-cli HLEN nscale:jobs | tr -d '\r')
    service_count=$(dc exec -T redis redis-cli HLEN nscale:jobs:services | tr -d '\r')

    if [[ "$job_count" != "0" || "$service_count" != "0" ]]; then
        fail "Expected Redis registry hashes to be empty after purge"
        exit 1
    fi
}

wait_for_job_running() {
    local elapsed=0
    while true; do
        if [ "$elapsed" -ge "$WAKE_TIMEOUT" ]; then
            fail "Job did not reach running state within ${WAKE_TIMEOUT}s"
            curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}/allocations" | jq .
            exit 1
        fi

        local status alloc_status
        status=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}" | jq -r '.Status // "unknown"' 2>/dev/null || echo "unknown")
        alloc_status=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}/allocations" | jq -r '.[0].ClientStatus // "pending"' 2>/dev/null || echo "pending")
        if [ "$status" = "running" ] && [ "$alloc_status" = "running" ]; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done
}

wait_for_deployment_complete() {
    local elapsed=0
    while true; do
        if [ "$elapsed" -ge 60 ]; then
            fail "Deployment did not complete within 60s"
            exit 1
        fi

        local deployment_status
        deployment_status=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}/deployments" | jq -r '.[0].Status // "null"')
        if [ "$deployment_status" = "successful" ] || [ "$deployment_status" = "null" ]; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done
}

wait_for_job_zero() {
    local elapsed=0
    while true; do
        if [ "$elapsed" -ge 30 ]; then
            fail "Job did not scale to zero within 30s"
            exit 1
        fi

        local running_allocs
        running_allocs=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}/allocations" | jq '[.[] | select(.ClientStatus == "running")] | length')
        if [ "$running_allocs" -eq 0 ]; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done
}

cleanup() {
    info "Cleaning up durable integration stack..."
    cd "$SCRIPT_DIR"
    dc down -v --remove-orphans 2>/dev/null || true
    docker network rm nscale-net 2>/dev/null || true
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

info "Starting durable integration stack..."
cd "$SCRIPT_DIR"
dc up -d --build

info "Waiting for all durable-mode services to be healthy..."
elapsed=0
while true; do
    if [ "$elapsed" -ge "$INFRA_TIMEOUT" ]; then
        fail "Durable integration stack did not start within ${INFRA_TIMEOUT}s"
        dc logs
        exit 1
    fi

    redis_ok=$(dc ps --format json | jq -r 'select(.Service=="redis") | .Health' 2>/dev/null || echo "unknown")
    consul_ok=$(dc ps --format json | jq -r 'select(.Service=="consul") | .Health' 2>/dev/null || echo "unknown")
    nomad_ok=$(dc ps --format json | jq -r 'select(.Service=="nomad") | .Health' 2>/dev/null || echo "unknown")
    etcd_ok=$(dc ps --format json | jq -r 'select(.Service=="etcd") | .Health' 2>/dev/null || echo "unknown")
    nscale_ok=$(dc ps --format json | jq -r 'select(.Service=="nscale") | .Health' 2>/dev/null || echo "unknown")
    traefik_ok=$(dc ps --format json | jq -r 'select(.Service=="traefik") | .Health' 2>/dev/null || echo "unknown")

    if [[ "$redis_ok" == "healthy" && "$consul_ok" == "healthy" && "$nomad_ok" == "healthy" && "$etcd_ok" == "healthy" && "$nscale_ok" == "healthy" && "$traefik_ok" == "healthy" ]]; then
        break
    fi

    sleep 3
    elapsed=$((elapsed + 3))
    echo "  ... waiting (${elapsed}s) redis=$redis_ok consul=$consul_ok nomad=$nomad_ok etcd=$etcd_ok nscale=$nscale_ok traefik=$traefik_ok"
done
pass "All durable-mode services healthy (${elapsed}s)"

info "Submitting variableized echo job through nscale admin API..."
SUBMIT_PAYLOAD=$(build_submit_payload)
SUBMIT_RESP=$(curl -sS -w "\n%{http_code}" -X POST "$NSCALE_ADMIN/admin/jobs" \
    -H "Content-Type: application/json" \
    -d "$SUBMIT_PAYLOAD")
SUBMIT_CODE=$(echo "$SUBMIT_RESP" | tail -1)
SUBMIT_BODY=$(echo "$SUBMIT_RESP" | sed '$d')

if [ "$SUBMIT_CODE" != "201" ]; then
    fail "nscale durable submission failed: HTTP $SUBMIT_CODE"
    echo "$SUBMIT_BODY"
    exit 1
fi
pass "Job submitted in durable mode"

info "Waiting for submitted job to become running..."
wait_for_job_running
pass "Job is running"

info "Verifying registration was persisted to Redis and etcd..."
assert_redis_registration_present
assert_etcd_registration_present
pass "Both Redis cache and etcd durable store contain the registration"

info "Warming the proxy path once before cache-loss checks..."
RESP=$(request_https 30)
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$HTTP_CODE" != "200" ]; then
    fail "Warm-path request failed before cache purge: HTTP $HTTP_CODE — $BODY"
    dc logs nscale traefik
    exit 1
fi
pass "Warm-path request succeeded before cache purge"

info "Purging Redis registry hashes to simulate cache loss..."
clear_redis_registry_cache
assert_redis_registry_empty
pass "Redis registry cache purged"

info "Making warm-path HTTPS request after Redis purge (should reload from etcd)..."
RESP=$(request_https 30)
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$HTTP_CODE" != "200" ]; then
    fail "Warm-path request failed after Redis purge: HTTP $HTTP_CODE — $BODY"
    dc logs nscale traefik
    exit 1
fi
assert_redis_registration_present
pass "Warm-path etcd fallback succeeded and Redis cache was repopulated"

info "Scaling job to zero to verify cold-start fallback after Redis loss..."
wait_for_deployment_complete
SCALE_RESP=$(curl -s -w "\n%{http_code}" -X POST "$NOMAD_ADDR/v1/job/${JOB_ID}/scale" \
    -H "Content-Type: application/json" \
    -d "{\"Count\":0,\"Target\":{\"Group\":\"${SERVICE_GROUP}\"},\"Message\":\"durable integration test: force scale-down\"}")
SCALE_CODE=$(echo "$SCALE_RESP" | tail -1)
if [[ ! "$SCALE_CODE" =~ ^2 ]]; then
    fail "Scale-down before cold-start check failed: HTTP $SCALE_CODE"
    exit 1
fi
wait_for_job_zero
pass "Job scaled to zero"

info "Purging Redis registry hashes again before cold-start request..."
clear_redis_registry_cache
assert_redis_registry_empty
pass "Redis registry cache purged before cold-start request"

info "Making HTTPS request after Redis purge and scale-to-zero (should wake via etcd fallback)..."
RESP=$(request_https "$WAKE_TIMEOUT")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$HTTP_CODE" != "200" ]; then
    fail "Cold-start request failed after Redis purge: HTTP $HTTP_CODE — $BODY"
    dc logs nscale traefik nomad
    exit 1
fi
assert_redis_registration_present
pass "Cold-start etcd fallback succeeded and Redis cache was repopulated"

echo ""
echo "========================================"
echo -e "${GREEN}  Durable integration test completed!${NC}"
echo "========================================"
echo ""
echo "Verified:"
echo "  1. nscale starts with etcd durable registry enabled"
echo "  2. /admin/jobs writes registrations to both etcd and Redis"
echo "  3. Redis registry cache loss is repaired on warm-path lookup via etcd fallback"
echo "  4. Redis registry cache loss is repaired on cold-start wake via etcd fallback"
echo "  5. service_name (${SERVICE_NAME}) lookup still works when job_id is ${JOB_ID}"
echo ""
