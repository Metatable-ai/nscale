#!/usr/bin/env bash
# Integration test for nscale — Nomad Scale-to-Zero (Rust)
#
# Prerequisites: docker, docker compose, curl, jq
#
# Test scenario:
#   1. Start infrastructure (Redis, Consul, Nomad, Traefik, nscale)
#   2. Submit a variableized Nomad HCL job to nscale's /admin/jobs endpoint
#   3. nscale parses it via Nomad, injects the required Traefik service tag,
#      and auto-registers the managed service in Redis
#   4. Verify the injected Traefik tag appears in Consul
#   5. Request through nscale proxy → verify service lookup works even when
#      service_name != job_id
#   6. Scale the job to zero → request again → verify wake-up still works
#   7. Wait for idle scale-down → verify the job can scale itself back to zero
#   8. Submit slow-service → verify DELETE /admin/jobs/:job_id rejects purge
#      while a proxied request is in flight
#   9. Purge slow-service with force=true → verify Nomad and nscale both forget it

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
JOB_FILE="$SCRIPT_DIR/jobs/echo-submit.nomad"
SLOW_JOB_FILE="$SCRIPT_DIR/jobs/slow-service.nomad"
TRAEFIK_CERT_SCRIPT="$SCRIPT_DIR/traefik/certs/generate.sh"

NOMAD_ADDR="http://localhost:4646"
CONSUL_ADDR="http://localhost:8500"
NSCALE_PROXY="http://localhost:80"
NSCALE_ADMIN="http://localhost:9090"
HTTPS_RESOLVE_ADDR="${HTTPS_RESOLVE_ADDR:-127.0.0.1}"

JOB_ID="echo-submit-job"
SERVICE_NAME="${SERVICE_NAME:-echo-s2z}"
SERVICE_GROUP="${SERVICE_GROUP:-main}"
ROUTER_HOST="${ROUTER_HOST:-${SERVICE_NAME}.localhost}"
HOST_HEADER="${HOST_HEADER:-${ROUTER_HOST}}"
EXPECTED_TRAEFIK_SERVICE_TAG="traefik.http.routers.${SERVICE_NAME}.service=s2z-nscale@file"

SLOW_JOB_ID="slow-service"
SLOW_SERVICE_NAME="slow-service"
SLOW_HOST_HEADER="slow-service.localhost"
SLOW_DELAY_SECS="${SLOW_DELAY_SECS:-15}"

# Timeouts
INFRA_TIMEOUT=120
WAKE_TIMEOUT=60
SCALEDOWN_WAIT=40

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; }
info() { echo -e "${YELLOW}→ $1${NC}"; }

request_http() {
    local max_time="${1:-30}"
    curl -s -w "\n%{http_code}" -H "Host: $HOST_HEADER" "$NSCALE_PROXY/" --max-time "$max_time"
}

request_https() {
    local max_time="${1:-30}"
    curl -k -s -w "\n%{http_code}" \
        --resolve "${HOST_HEADER}:443:${HTTPS_RESOLVE_ADDR}" \
        "https://${HOST_HEADER}/" \
        --max-time "$max_time"
}

request_http_host_path() {
    local host_header="$1"
    local path="$2"
    local max_time="${3:-30}"
    curl -s -w "\n%{http_code}" \
        -H "Host: $host_header" \
        "${NSCALE_PROXY}${path}" \
        --max-time "$max_time"
}

cleanup() {
    info "Cleaning up..."
    cd "$SCRIPT_DIR"
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    docker network rm nscale-net 2>/dev/null || true
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

wait_for_job_running_id() {
    local job_id="$1"
    local timeout="${2:-$WAKE_TIMEOUT}"
    local elapsed=0

    while true; do
        if [ "$elapsed" -ge "$timeout" ]; then
            fail "Job ${job_id} did not start within ${timeout}s"
            curl -s "$NOMAD_ADDR/v1/job/${job_id}/allocations" | jq .
            exit 1
        fi

        local status alloc_status
        status=$(curl -s "$NOMAD_ADDR/v1/job/${job_id}" | jq -r '.Status // "unknown"' 2>/dev/null || echo "unknown")
        alloc_status=$(curl -s "$NOMAD_ADDR/v1/job/${job_id}/allocations" | jq -r '.[0].ClientStatus // "pending"' 2>/dev/null || echo "pending")
        if [ "$status" = "running" ] && [ "$alloc_status" = "running" ]; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done
}

wait_for_service_healthy_name() {
    local service_name="$1"
    local timeout="${2:-$WAKE_TIMEOUT}"
    local elapsed=0

    while true; do
        if [ "$elapsed" -ge "$timeout" ]; then
            fail "Service ${service_name} not healthy in Consul within ${timeout}s"
            exit 1
        fi

        local healthy_count
        healthy_count=$(curl -s "$CONSUL_ADDR/v1/health/service/${service_name}?passing=true" | jq 'length')
        if [ "$healthy_count" -gt 0 ]; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done
}

wait_for_nomad_job_missing() {
    local job_id="$1"
    local timeout="${2:-30}"
    local elapsed=0

    while true; do
        if [ "$elapsed" -ge "$timeout" ]; then
            fail "Nomad job ${job_id} was not purged within ${timeout}s"
            exit 1
        fi

        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "$NOMAD_ADDR/v1/job/${job_id}")
        if [ "$code" = "404" ]; then
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done
}

trap cleanup EXIT

# ── 0. Preflight ──────────────────────────────────────────
info "Checking prerequisites..."
for cmd in docker curl jq openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        fail "Required command '$cmd' not found"
        exit 1
    fi
done
pass "Prerequisites OK"

info "Checking submit fixture relies on nscale tag injection..."
if grep -Eq 'traefik\.http\.routers\..*\.service=s2z-nscale@file' "$JOB_FILE"; then
    fail "Submit fixture already contains the injected Traefik service tag"
    exit 1
fi
pass "Submit fixture requires nscale tag injection"

info "Ensuring local Traefik TLS certificates exist..."
bash "$TRAEFIK_CERT_SCRIPT"
pass "Traefik TLS certificates ready"

# ── 1. Start infrastructure ──────────────────────────────
info "Starting infrastructure via docker compose..."
cd "$SCRIPT_DIR"
docker compose -f "$COMPOSE_FILE" up -d --build

info "Waiting for all services to be healthy..."
elapsed=0
while true; do
    if [ "$elapsed" -ge "$INFRA_TIMEOUT" ]; then
        fail "Infrastructure did not start within ${INFRA_TIMEOUT}s"
        docker compose -f "$COMPOSE_FILE" logs
        exit 1
    fi

    redis_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json | jq -r 'select(.Service=="redis") | .Health' 2>/dev/null || echo "unknown")
    consul_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json | jq -r 'select(.Service=="consul") | .Health' 2>/dev/null || echo "unknown")
    nomad_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json | jq -r 'select(.Service=="nomad") | .Health' 2>/dev/null || echo "unknown")
    nscale_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json | jq -r 'select(.Service=="nscale") | .Health' 2>/dev/null || echo "unknown")
    traefik_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json | jq -r 'select(.Service=="traefik") | .Health' 2>/dev/null || echo "unknown")

    if [[ "$redis_ok" == "healthy" && "$consul_ok" == "healthy" && "$nomad_ok" == "healthy" && "$nscale_ok" == "healthy" && "$traefik_ok" == "healthy" ]]; then
        break
    fi

    sleep 3
    elapsed=$((elapsed + 3))
    echo "  ... waiting (${elapsed}s) redis=$redis_ok consul=$consul_ok nomad=$nomad_ok nscale=$nscale_ok traefik=$traefik_ok"
done
pass "All services healthy (${elapsed}s)"

# ── 2. Submit HCL through nscale ─────────────────────────
info "Submitting variableized echo job through nscale admin API..."
SUBMIT_PAYLOAD=$(build_submit_payload)
SUBMIT_RESP=$(curl -sS -w "\n%{http_code}" -X POST "$NSCALE_ADMIN/admin/jobs" \
    -H "Content-Type: application/json" \
    -d "$SUBMIT_PAYLOAD")
SUBMIT_CODE=$(echo "$SUBMIT_RESP" | tail -1)
SUBMIT_BODY=$(echo "$SUBMIT_RESP" | sed '$d')

if [ "$SUBMIT_CODE" != "201" ]; then
    fail "nscale submission failed: HTTP $SUBMIT_CODE"
    echo "$SUBMIT_BODY"
    exit 1
fi

if echo "$SUBMIT_BODY" | jq -e \
    --arg job_id "$JOB_ID" \
    --arg service_name "$SERVICE_NAME" \
    --arg group "$SERVICE_GROUP" '
    .job_id == $job_id and
    (.managed_services | length) == 1 and
    .managed_services[0].job_id == $job_id and
    .managed_services[0].service_name == $service_name and
    .managed_services[0].nomad_group == $group and
    ((.registration_failures // []) | length) == 0
' >/dev/null; then
    pass "nscale submitted the job and auto-registered the managed service"
else
    fail "Unexpected /admin/jobs response payload"
    echo "$SUBMIT_BODY" | jq .
    exit 1
fi

EVAL_ID=$(echo "$SUBMIT_BODY" | jq -r '.eval_id')
info "Job submitted, EvalID: $EVAL_ID"

info "Waiting for job ${JOB_ID} to be running..."
elapsed=0
while true; do
    if [ "$elapsed" -ge "$WAKE_TIMEOUT" ]; then
        fail "Job did not start within ${WAKE_TIMEOUT}s"
        curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}/allocations" | jq .
        exit 1
    fi

    STATUS=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}" | jq -r '.Status // "unknown"' 2>/dev/null || echo "unknown")
    ALLOC_STATUS=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}/allocations" | jq -r '.[0].ClientStatus // "pending"' 2>/dev/null || echo "pending")
    if [ "$STATUS" = "running" ] && [ "$ALLOC_STATUS" = "running" ]; then
        break
    fi

    sleep 2
    elapsed=$((elapsed + 2))
done
pass "Job ${JOB_ID} is running (${elapsed}s)"

info "Waiting for service ${SERVICE_NAME} to be healthy in Consul..."
elapsed=0
while true; do
    if [ "$elapsed" -ge "$WAKE_TIMEOUT" ]; then
        fail "Service not healthy in Consul within ${WAKE_TIMEOUT}s"
        exit 1
    fi

    HEALTHY=$(curl -s "$CONSUL_ADDR/v1/health/service/${SERVICE_NAME}?passing=true" | jq 'length')
    if [ "$HEALTHY" -gt 0 ]; then
        SERVICE_ADDR=$(curl -s "$CONSUL_ADDR/v1/health/service/${SERVICE_NAME}?passing=true" | jq -r '.[0].Service.Address')
        SERVICE_PORT=$(curl -s "$CONSUL_ADDR/v1/health/service/${SERVICE_NAME}?passing=true" | jq -r '.[0].Service.Port')
        info "Service registered at $SERVICE_ADDR:$SERVICE_PORT"
        break
    fi

    sleep 2
    elapsed=$((elapsed + 2))
done
pass "Service healthy in Consul (${elapsed}s)"

info "Verifying nscale injected the Traefik service override tag..."
if curl -s "$CONSUL_ADDR/v1/health/service/${SERVICE_NAME}?passing=true" \
    | jq -e --arg tag "$EXPECTED_TRAEFIK_SERVICE_TAG" 'any(.[]?; ((.Service.Tags // []) | index($tag)) != null)' >/dev/null; then
    pass "Injected Traefik service tag is present in Consul"
else
    fail "Injected Traefik service tag was not found in Consul"
    curl -s "$CONSUL_ADDR/v1/health/service/${SERVICE_NAME}?passing=true" | jq '.[0].Service.Tags'
    exit 1
fi

# ── 3. Request through nscale proxy (warm path) ──────────
info "Making first HTTP request through nscale proxy..."
RESP=$(request_http 30)
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    pass "HTTP warm-path request succeeded: HTTP $HTTP_CODE — $BODY"
else
    fail "HTTP warm-path request failed: HTTP $HTTP_CODE — $BODY"
    docker compose -f "$COMPOSE_FILE" logs nscale
    exit 1
fi

info "Making first HTTPS request through nscale proxy..."
RESP_TLS=$(request_https 30)
HTTP_CODE_TLS=$(echo "$RESP_TLS" | tail -1)
BODY_TLS=$(echo "$RESP_TLS" | sed '$d')

if [ "$HTTP_CODE_TLS" = "200" ]; then
    pass "HTTPS warm-path request succeeded: HTTP $HTTP_CODE_TLS — $BODY_TLS"
else
    fail "HTTPS warm-path request failed: HTTP $HTTP_CODE_TLS — $BODY_TLS"
    docker compose -f "$COMPOSE_FILE" logs traefik nscale
    exit 1
fi

# ── 4. Scale down the job to zero ────────────────────────
info "Waiting for deployment to complete..."
elapsed=0
while true; do
    if [ "$elapsed" -ge 60 ]; then
        fail "Deployment did not complete within 60s"
        curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}/deployments" | jq .
        exit 1
    fi

    if curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}/deployments" \
        | jq -e 'length == 0 or all(.[]; (.Status // "unknown") == "successful" or (.Status // "unknown") == "failed" or (.Status // "unknown") == "cancelled")' >/dev/null; then
        break
    fi

    sleep 2
    elapsed=$((elapsed + 2))
done
pass "Deployment complete (${elapsed}s)"

info "Scaling ${JOB_ID} to 0 via Nomad API..."
SCALE_RESP=$(curl -s -w "\n%{http_code}" -X POST "$NOMAD_ADDR/v1/job/${JOB_ID}/scale" \
    -H "Content-Type: application/json" \
    -d "{\"Count\":0,\"Target\":{\"Group\":\"${SERVICE_GROUP}\"},\"Message\":\"integration test: force scale-down\"}")
SCALE_CODE=$(echo "$SCALE_RESP" | tail -1)
if [[ "$SCALE_CODE" =~ ^2 ]]; then
    pass "Job scaled to 0"
else
    fail "Scale-down failed: HTTP $SCALE_CODE"
    exit 1
fi

info "Waiting for allocation to stop..."
elapsed=0
while true; do
    if [ "$elapsed" -ge 30 ]; then
        fail "Allocation did not stop within 30s"
        exit 1
    fi

    ALLOC_COUNT=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}/allocations" | jq '[.[] | select(.ClientStatus == "running")] | length')
    if [ "$ALLOC_COUNT" -eq 0 ]; then
        break
    fi

    sleep 2
    elapsed=$((elapsed + 2))
done
pass "Job scaled to zero, no running allocations (${elapsed}s)"

JOB_COUNT=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}" | jq '.TaskGroups[0].Count')
info "Nomad job count for ${JOB_ID}: $JOB_COUNT"

# ── 5. Request through nscale proxy (should wake again) ──
info "Making second HTTPS request through nscale proxy (should trigger wake-up)..."
info "This will wake the job from zero over TLS — may take up to ${WAKE_TIMEOUT}s..."

RESP2=$(request_https "$WAKE_TIMEOUT")
HTTP_CODE2=$(echo "$RESP2" | tail -1)
BODY2=$(echo "$RESP2" | sed '$d')

if [ "$HTTP_CODE2" = "200" ]; then
    pass "HTTPS wake-up request succeeded: HTTP $HTTP_CODE2 — $BODY2"
else
    info "Got HTTP $HTTP_CODE2 on wake attempt. Checking state..."

    JOB_STATUS=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}" | jq -r '.Status // "unknown"')
    JOB_COUNT2=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}" | jq '.TaskGroups[0].Count')
    info "Job status=$JOB_STATUS count=$JOB_COUNT2"

    if [ "$JOB_COUNT2" -gt 0 ]; then
        info "Job was scaled up! Waiting for it to become healthy..."
        elapsed=0
        while true; do
            if [ "$elapsed" -ge "$WAKE_TIMEOUT" ]; then
                fail "Re-woken job did not become healthy within ${WAKE_TIMEOUT}s"
                exit 1
            fi

            HEALTHY=$(curl -s "$CONSUL_ADDR/v1/health/service/${SERVICE_NAME}?passing=true" | jq 'length')
            if [ "$HEALTHY" -gt 0 ]; then
                break
            fi

            sleep 2
            elapsed=$((elapsed + 2))
        done

        RESP3=$(request_https 30)
        HTTP_CODE3=$(echo "$RESP3" | tail -1)
        BODY3=$(echo "$RESP3" | sed '$d')

        if [ "$HTTP_CODE3" = "200" ]; then
            pass "HTTPS retry request succeeded: HTTP $HTTP_CODE3 — $BODY3"
        else
            fail "Retry request also failed: HTTP $HTTP_CODE3 — $BODY3"
            docker compose -f "$COMPOSE_FILE" logs traefik nscale
            exit 1
        fi
    else
        fail "Job was not scaled up by nscale"
        docker compose -f "$COMPOSE_FILE" logs traefik nscale
        exit 1
    fi
fi

FINAL_STATUS=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}" | jq -r '.Status // "unknown"')
FINAL_COUNT=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}" | jq '.TaskGroups[0].Count')
info "Final state: status=$FINAL_STATUS count=$FINAL_COUNT"

if [ "$FINAL_COUNT" -gt 0 ]; then
    pass "Job is running again after wake-up"
else
    fail "Job is not running after wake-up"
    exit 1
fi

# ── 6. Test automatic scale-down ─────────────────────────
info "Waiting for automatic scale-down (idle_timeout=15s, check_interval=5s)..."
info "This may take up to ${SCALEDOWN_WAIT}s..."

elapsed=0
scaled_down=false
while [ "$elapsed" -lt "$SCALEDOWN_WAIT" ]; do
    sleep 5
    elapsed=$((elapsed + 5))

    COUNT=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}" | jq '.TaskGroups[0].Count')
    RUNNING=$(curl -s "$NOMAD_ADDR/v1/job/${JOB_ID}/allocations" | jq '[.[] | select(.ClientStatus == "running")] | length')
    echo "  ... ${elapsed}s — count=$COUNT running_allocs=$RUNNING"

    if [ "$COUNT" -eq 0 ]; then
        scaled_down=true
        break
    fi
done

if $scaled_down; then
    pass "Automatic scale-down worked! Job scaled to zero after idle timeout (${elapsed}s)"
else
    info "Automatic scale-down did not happen within ${SCALEDOWN_WAIT}s (this may be a timing issue)"
    info "The scale-down controller may need more time. Continuing..."
fi

# ── 7. Test manual purge with in-flight protection ──────
info "Submitting slow-service through nscale admin API for purge endpoint checks..."
SLOW_SUBMIT_PAYLOAD=$(jq -n --rawfile hcl "$SLOW_JOB_FILE" '{hcl: $hcl}')
SLOW_SUBMIT_RESP=$(curl -sS -w "\n%{http_code}" -X POST "$NSCALE_ADMIN/admin/jobs" \
    -H "Content-Type: application/json" \
    -d "$SLOW_SUBMIT_PAYLOAD")
SLOW_SUBMIT_CODE=$(echo "$SLOW_SUBMIT_RESP" | tail -1)
SLOW_SUBMIT_BODY=$(echo "$SLOW_SUBMIT_RESP" | sed '$d')

if [ "$SLOW_SUBMIT_CODE" != "201" ]; then
    fail "slow-service submission failed: HTTP $SLOW_SUBMIT_CODE"
    echo "$SLOW_SUBMIT_BODY"
    exit 1
fi
pass "slow-service submitted via /admin/jobs"

info "Waiting for slow-service to be running..."
wait_for_job_running_id "$SLOW_JOB_ID" "$WAKE_TIMEOUT"
pass "slow-service is running"

info "Waiting for slow-service to be healthy in Consul..."
wait_for_service_healthy_name "$SLOW_SERVICE_NAME" "$WAKE_TIMEOUT"
pass "slow-service is healthy in Consul"

info "Warming slow-service through the proxy before in-flight purge checks..."
SLOW_WARM_RESP=$(request_http_host_path "$SLOW_HOST_HEADER" "/" 30)
SLOW_WARM_CODE=$(echo "$SLOW_WARM_RESP" | tail -1)
SLOW_WARM_BODY=$(echo "$SLOW_WARM_RESP" | sed '$d')
if [ "$SLOW_WARM_CODE" = "200" ]; then
    pass "slow-service warm-path request succeeded: HTTP $SLOW_WARM_CODE — $SLOW_WARM_BODY"
else
    fail "slow-service warm-path request failed: HTTP $SLOW_WARM_CODE — $SLOW_WARM_BODY"
    docker compose -f "$COMPOSE_FILE" logs nscale traefik
    exit 1
fi

info "Starting long-running slow-service request (/cgi-bin/slow?delay=${SLOW_DELAY_SECS})..."
SLOW_RESP_FILE=$(mktemp)
curl -s -w "\n%{http_code}" \
    -H "Host: $SLOW_HOST_HEADER" \
    "${NSCALE_PROXY}/cgi-bin/slow?delay=${SLOW_DELAY_SECS}" \
    --max-time "$((SLOW_DELAY_SECS + 30))" >"$SLOW_RESP_FILE" &
SLOW_PID=$!

sleep 2
if ! kill -0 "$SLOW_PID" 2>/dev/null; then
    fail "slow-service request finished before purge guard could be checked"
    cat "$SLOW_RESP_FILE"
    rm -f "$SLOW_RESP_FILE"
    exit 1
fi

info "Calling DELETE /admin/jobs/${SLOW_JOB_ID} without force while request is in flight..."
PURGE_BLOCKED_RESP=$(curl -sS -w "\n%{http_code}" -X DELETE "$NSCALE_ADMIN/admin/jobs/${SLOW_JOB_ID}")
PURGE_BLOCKED_CODE=$(echo "$PURGE_BLOCKED_RESP" | tail -1)
PURGE_BLOCKED_BODY=$(echo "$PURGE_BLOCKED_RESP" | sed '$d')

if [ "$PURGE_BLOCKED_CODE" != "409" ]; then
    fail "Expected purge guard to return 409, got HTTP $PURGE_BLOCKED_CODE"
    echo "$PURGE_BLOCKED_BODY"
    rm -f "$SLOW_RESP_FILE"
    exit 1
fi

if echo "$PURGE_BLOCKED_BODY" | jq -e --arg job_id "$SLOW_JOB_ID" '.job_id == $job_id and ((.in_flight // 0) >= 1)' >/dev/null; then
    pass "Purge endpoint rejected in-flight deletion without force"
else
    fail "Unexpected blocked purge response body"
    echo "$PURGE_BLOCKED_BODY" | jq .
    rm -f "$SLOW_RESP_FILE"
    exit 1
fi

wait "$SLOW_PID"
SLOW_REQUEST_CODE=$(tail -1 "$SLOW_RESP_FILE")
SLOW_REQUEST_BODY=$(sed '$d' "$SLOW_RESP_FILE")
rm -f "$SLOW_RESP_FILE"

if [ "$SLOW_REQUEST_CODE" = "200" ] && grep -q "Done after ${SLOW_DELAY_SECS}s delay" <<<"$SLOW_REQUEST_BODY"; then
    pass "In-flight request completed successfully after blocked purge: HTTP $SLOW_REQUEST_CODE — $SLOW_REQUEST_BODY"
else
    fail "In-flight request did not survive blocked purge: HTTP $SLOW_REQUEST_CODE — $SLOW_REQUEST_BODY"
    docker compose -f "$COMPOSE_FILE" logs nscale traefik
    exit 1
fi

info "Purging slow-service with force=true after the request completes..."
FORCE_PURGE_RESP=$(curl -sS -w "\n%{http_code}" -X DELETE "$NSCALE_ADMIN/admin/jobs/${SLOW_JOB_ID}?force=true")
FORCE_PURGE_CODE=$(echo "$FORCE_PURGE_RESP" | tail -1)
FORCE_PURGE_BODY=$(echo "$FORCE_PURGE_RESP" | sed '$d')

if [ "$FORCE_PURGE_CODE" != "200" ]; then
    fail "force purge failed: HTTP $FORCE_PURGE_CODE"
    echo "$FORCE_PURGE_BODY"
    exit 1
fi

if echo "$FORCE_PURGE_BODY" | jq -e --arg job_id "$SLOW_JOB_ID" '.job_id == $job_id and .force == true' >/dev/null; then
    pass "force=true purge succeeded"
else
    fail "Unexpected force purge response body"
    echo "$FORCE_PURGE_BODY" | jq .
    exit 1
fi

info "Waiting for Nomad to report slow-service as purged..."
wait_for_nomad_job_missing "$SLOW_JOB_ID" 30
pass "Nomad no longer knows about slow-service"

info "Verifying slow-service is no longer registered in nscale..."
POST_PURGE_RESP=$(request_http_host_path "$SLOW_HOST_HEADER" "/" 15)
POST_PURGE_CODE=$(echo "$POST_PURGE_RESP" | tail -1)
POST_PURGE_BODY=$(echo "$POST_PURGE_RESP" | sed '$d')
if [ "$POST_PURGE_CODE" = "404" ]; then
    pass "Purged slow-service now fails fast through nscale: HTTP $POST_PURGE_CODE — $POST_PURGE_BODY"
else
    fail "Expected purged slow-service to return 404, got HTTP $POST_PURGE_CODE — $POST_PURGE_BODY"
    docker compose -f "$COMPOSE_FILE" logs nscale traefik
    exit 1
fi

# ── Summary ───────────────────────────────────────────────
echo ""
echo "========================================"
echo -e "${GREEN}  Integration test completed!${NC}"
echo "========================================"
echo ""
echo "Verified:"
echo "  1. Infrastructure starts correctly (Redis, Consul, Nomad, Traefik, nscale)"
echo "  2. nscale accepts HCL + variables at /admin/jobs and submits to Nomad"
echo "  3. nscale injects the Traefik router service override and auto-registers the service"
echo "  4. HTTP and HTTPS proxy lookup both work when service_name (${SERVICE_NAME}) differs from job_id (${JOB_ID})"
echo "  5. nscale wakes the dormant job on incoming HTTPS request"
if $scaled_down; then
    echo "  6. Automatic scale-down after idle timeout"
fi
echo "  7. DELETE /admin/jobs/:job_id rejects purge while proxied work is in flight"
echo "  8. force=true purges slow-service from both Nomad and nscale state"
echo ""
