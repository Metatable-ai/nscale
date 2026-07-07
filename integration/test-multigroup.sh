#!/usr/bin/env bash
# Integration test for nscale multi-group scale-to-zero.
#
# A single Nomad job ("multi-group-s2z") exposes two independent task groups
# ("alpha" and "beta"), each with its own Consul service and Traefik router.
# nscale must scale, idle-detect, and wake each GROUP independently.
#
# Prerequisites: docker, docker compose, curl, jq, openssl.
# Opt-in: drives traffic through the full Nomad/Consul/Traefik/nscale stack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
JOB_FILE="$SCRIPT_DIR/jobs/multi-group-s2z.nomad"
TRAEFIK_CERT_SCRIPT="$SCRIPT_DIR/traefik/certs/generate.sh"

NOMAD_ADDR="http://localhost:4646"
NSCALE_PROXY="http://localhost:80"
NSCALE_ADMIN="http://localhost:9090"

JOB_ID="multi-group-s2z"
ALPHA_GROUP="alpha"
BETA_GROUP="beta"
ALPHA_SVC="mg-alpha"
BETA_SVC="mg-beta"

INFRA_TIMEOUT=120
WAKE_TIMEOUT=90
SCALEDOWN_TIMEOUT=120

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
        info "Multi-group integration failed; collecting diagnostics..."
        docker compose -f "$COMPOSE_FILE" logs nscale traefik nomad || true
        curl -fsS "$NOMAD_ADDR/v1/job/${JOB_ID}" | jq '.TaskGroups[] | {Name, Count}' || true
    fi
    info "Cleaning up multi-group integration stack..."
    cd "$SCRIPT_DIR"
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    docker network rm nscale-net 2>/dev/null || true
}
trap cleanup EXIT

request_host_path() {
    local service_name="$1"
    local path="${2:-/}"
    local max_time="${3:-30}"
    curl -s -o /dev/null -w "%{http_code}" \
        -H "Host: ${service_name}.localhost" \
        "${NSCALE_PROXY}${path}" \
        --max-time "$max_time"
}

# Per-GROUP count (not TaskGroups[0] — that assumes a single group).
group_count() {
    local job_id="$1" group="$2"
    curl -s "$NOMAD_ADDR/v1/job/${job_id}" \
        | jq --arg g "$group" '[.TaskGroups[] | select(.Name == $g) | .Count] | first // 0'
}

group_running_allocs() {
    local job_id="$1" group="$2"
    curl -s "$NOMAD_ADDR/v1/job/${job_id}/allocations" \
        | jq --arg g "$group" \
            '[.[] | select(.TaskGroup == $g and .ClientStatus == "running")] | length'
}

wait_for_group_running() {
    local job_id="$1" group="$2" timeout="${3:-$WAKE_TIMEOUT}" elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local count running
        count=$(group_count "$job_id" "$group" 2>/dev/null || echo 0)
        running=$(group_running_allocs "$job_id" "$group" 2>/dev/null || echo 0)
        if [ "$count" -gt 0 ] && [ "$running" -gt 0 ]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    fail "Group ${job_id}/${group} did not become running within ${timeout}s"
    exit 1
}

wait_for_group_count_exact() {
    local job_id="$1" group="$2" expected="$3" timeout="${4:-$SCALEDOWN_TIMEOUT}" elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local count
        count=$(group_count "$job_id" "$group")
        echo "  ... ${elapsed}s ${job_id}/${group} count=${count}, expecting ${expected}"
        if [ "$count" -eq "$expected" ]; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    fail "Group ${job_id}/${group} did not reach count ${expected} within ${timeout}s"
    docker compose -f "$COMPOSE_FILE" logs nscale || true
    exit 1
}

assert_group_count() {
    local job_id="$1" group="$2" expected="$3"
    local count
    count=$(group_count "$job_id" "$group")
    if [ "$count" -eq "$expected" ]; then
        pass "${job_id}/${group} count == ${expected}"
    else
        fail "${job_id}/${group} count == ${count}, expected ${expected}"
        exit 1
    fi
}

# ── Stack bring-up ────────────────────────────────────────────
info "Generating Traefik certs..."
[ -x "$TRAEFIK_CERT_SCRIPT" ] && "$TRAEFIK_CERT_SCRIPT" || true

info "Starting stack..."
cd "$SCRIPT_DIR"
docker compose -f "$COMPOSE_FILE" up -d --build

info "Waiting for nscale admin to be ready..."
elapsed=0
while [ "$elapsed" -lt "$INFRA_TIMEOUT" ]; do
    if curl -fsS "$NSCALE_ADMIN/healthz" >/dev/null 2>&1; then break; fi
    sleep 2; elapsed=$((elapsed + 2))
done

# ── Submit the multi-group job (registers BOTH groups) ────────
info "Submitting multi-group job via /admin/jobs..."
payload=$(jq -n --rawfile hcl "$JOB_FILE" '{hcl: $hcl}')
submit_code=$(curl -sS -o /tmp/mg-submit.json -w "%{http_code}" -X POST "$NSCALE_ADMIN/admin/jobs" \
    -H "Content-Type: application/json" -d "$payload")
# /admin/jobs returns 201 Created on success (207 Multi-Status on partial failure).
if [ "$submit_code" != "200" ] && [ "$submit_code" != "201" ]; then
    fail "job submission failed (HTTP ${submit_code})"; cat /tmp/mg-submit.json; exit 1
fi
managed=$(jq '.managed_services | length' /tmp/mg-submit.json)
[ "$managed" -eq 2 ] && pass "both groups registered (managed_services=2)" \
    || { fail "expected 2 managed services, got ${managed}"; cat /tmp/mg-submit.json; exit 1; }

info "Waiting for both groups to be running..."
wait_for_group_running "$JOB_ID" "$ALPHA_GROUP"
wait_for_group_running "$JOB_ID" "$BETA_GROUP"
pass "both groups running"

# ── Both groups scale to zero when idle ───────────────────────
info "Waiting for both idle groups to scale to zero..."
wait_for_group_count_exact "$JOB_ID" "$ALPHA_GROUP" 0
wait_for_group_count_exact "$JOB_ID" "$BETA_GROUP" 0
pass "both groups scaled to zero independently"

# ── Wake alpha only; beta must stay at zero ───────────────────
info "Requesting ${ALPHA_SVC} (wakes alpha only)..."
code=$(request_host_path "$ALPHA_SVC" / 60)
[ "$code" = "200" ] && pass "alpha responded 200 after cold start" \
    || { fail "alpha wake returned ${code}"; exit 1; }
wait_for_group_running "$JOB_ID" "$ALPHA_GROUP"
assert_group_count "$JOB_ID" "$ALPHA_GROUP" 1
# Key independence assertion: beta did NOT wake.
assert_group_count "$JOB_ID" "$BETA_GROUP" 0
pass "waking alpha left beta at zero (independent wake)"

# ── Wake beta independently ───────────────────────────────────
info "Requesting ${BETA_SVC} (wakes beta)..."
code=$(request_host_path "$BETA_SVC" / 60)
[ "$code" = "200" ] && pass "beta responded 200 after cold start" \
    || { fail "beta wake returned ${code}"; exit 1; }
wait_for_group_running "$JOB_ID" "$BETA_GROUP"
assert_group_count "$JOB_ID" "$BETA_GROUP" 1

# ── Independent scale-down: keep beta warm, let alpha idle ────
info "Keeping beta warm while alpha idles; expect alpha->0, beta stays up..."
for _ in $(seq 1 "$SCALEDOWN_TIMEOUT"); do
    request_host_path "$BETA_SVC" / 5 >/dev/null || true
    a=$(group_count "$JOB_ID" "$ALPHA_GROUP")
    if [ "$a" -eq 0 ]; then break; fi
    sleep 1
done
assert_group_count "$JOB_ID" "$ALPHA_GROUP" 0
assert_group_count "$JOB_ID" "$BETA_GROUP" 1
pass "alpha scaled to zero while beta stayed up (independent scale-down)"

pass "ALL MULTI-GROUP INTEGRATION CHECKS PASSED"
