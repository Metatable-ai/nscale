#!/usr/bin/env bash
# stress-test.sh — k6 stress test runner for nscale Rust integration.
#
# Scenarios (run in order unless --scenario=<name> is specified):
#   coldstart  — N VUs simultaneously hit a dormant service (tests wake dedup)
#   load       — sustained ramp from 0 → 20 VUs (tests warm-path throughput)
#   storm      — ramping-arrival-rate cold-start burst (tests concurrent wakes)
#   soak       — long low-rate test with natural idle scale-down cycles
#
# Usage:
#   ./stress-test.sh                      # run all scenarios
#   ./stress-test.sh --scenario=storm     # single scenario
#   ./stress-test.sh --start              # start infra first, then run all
#   ./stress-test.sh --start --scenario=load
#
# Prerequisites: docker, docker compose, curl, jq
# The integration infrastructure (docker compose up) must be running unless
# --start is passed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
JOB_FILE="$SCRIPT_DIR/jobs/echo-s2z.nomad"

NOMAD_ADDR="http://localhost:4646"
NSCALE_ADMIN="http://localhost:9090"

SCENARIO=""
START_INFRA=false

for arg in "$@"; do
  case "$arg" in
    --scenario=*) SCENARIO="${arg#*=}" ;;
    --start)      START_INFRA=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
pass()   { echo -e "${GREEN}✓ $1${NC}"; }
fail()   { echo -e "${RED}✗ $1${NC}"; exit 1; }
info()   { echo -e "${YELLOW}→ $1${NC}"; }
header() { echo -e "\n${CYAN}══ $1 ══${NC}"; }

# ── 0. Optionally start infrastructure ───────────────────
if $START_INFRA; then
  header "Starting infrastructure"
  cd "$SCRIPT_DIR"
  docker compose -f "$COMPOSE_FILE" up -d --build

  info "Waiting for services to be healthy..."
  elapsed=0
  while true; do
    [ "$elapsed" -ge 120 ] && fail "Infrastructure did not start within 120s"
    all_health=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
      | jq -r 'select(.Service != "k6") | .Health' 2>/dev/null | sort -u || echo "unknown")
    if ! echo "$all_health" | grep -qv "healthy"; then
      break
    fi
    sleep 3; elapsed=$((elapsed + 3))
    echo "  ...${elapsed}s"
  done
  pass "Infrastructure healthy (${elapsed}s)"
fi

# ── 1. Verify infrastructure is running ───────────────────
header "Pre-flight checks"
for svc in redis consul nomad nscale traefik; do
  health=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
    | jq -r --arg s "$svc" 'select(.Service==$s) | .Health' 2>/dev/null || echo "unknown")
  if [ "$health" != "healthy" ]; then
    fail "$svc is not healthy (got: $health). Run with --start or start infra manually."
  fi
  pass "$svc healthy"
done

# ── 2. Ensure job exists and is registered in nscale ─────
header "Job setup"
info "Submitting echo-s2z to Nomad (idempotent)..."
JOB_HCL=$(cat "$JOB_FILE")
JOB_JSON=$(curl -fsS "$NOMAD_ADDR/v1/jobs/parse" \
  -X POST \
  -d "{\"JobHCL\": $(echo "$JOB_HCL" | jq -Rs .), \"Canonicalize\": true}" \
  -H "Content-Type: application/json")
curl -fsS "$NOMAD_ADDR/v1/jobs" \
  -X POST \
  -d "{\"Job\": $JOB_JSON}" \
  -H "Content-Type: application/json" > /dev/null
pass "Job submitted"

info "Waiting for echo-s2z to be running..."
elapsed=0
while true; do
  [ "$elapsed" -ge 60 ] && fail "Job did not start within 60s"
  STATUS=$(curl -s "$NOMAD_ADDR/v1/job/echo-s2z" | jq -r '.Status')
  ALLOC=$(curl -s "$NOMAD_ADDR/v1/job/echo-s2z/allocations" \
    | jq -r '[.[] | select(.ClientStatus=="running")] | length')
  [ "$STATUS" = "running" ] && [ "$ALLOC" -gt 0 ] && break
  sleep 2; elapsed=$((elapsed + 2))
done
pass "Job running (${elapsed}s)"

info "Waiting for echo-s2z to be healthy in Consul..."
elapsed=0
while true; do
  [ "$elapsed" -ge 60 ] && fail "Service not healthy in Consul within 60s"
  HEALTHY=$(curl -s "http://localhost:8500/v1/health/service/echo-s2z?passing=true" | jq 'length')
  [ "$HEALTHY" -gt 0 ] && break
  sleep 2; elapsed=$((elapsed + 2))
done
pass "Service healthy in Consul (${elapsed}s)"

info "Registering echo-s2z in nscale (idempotent)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$NSCALE_ADMIN/admin/registry" \
  -H "Content-Type: application/json" \
  -d '{"job_id":"echo-s2z","service_name":"echo-s2z","nomad_group":"main"}')
[ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "409" ] || fail "Registration failed: HTTP $HTTP_CODE"
pass "echo-s2z registered (HTTP $HTTP_CODE)"

# ── 3. Run k6 scenarios ───────────────────────────────────
run_k6() {
  local name="$1"; shift
  local script="$1"; shift
  header "k6 scenario: $name"

  # Pass any extra env vars as -e KEY=VAL flags
  local env_flags=()
  for kv in "$@"; do
    env_flags+=(-e "$kv")
  done

  docker compose -f "$COMPOSE_FILE" --profile stress run --rm \
    "${env_flags[@]+"${env_flags[@]}"}" \
    k6 run "/scripts/${script}"

  echo ""
}

RESULTS_DIR="$SCRIPT_DIR/.stress-results/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RESULTS_DIR"
info "Results dir: $RESULTS_DIR"

run_scenario() {
  local name="$1"; shift
  local script="$1"; shift

  header "k6 scenario: $name"

  local env_flags=()
  for kv in "$@"; do
    env_flags+=(-e "$kv")
  done

  docker compose -f "$COMPOSE_FILE" --profile stress run --rm \
    "${env_flags[@]+"${env_flags[@]}"}" \
    -e "K6_WEB_DASHBOARD_PERIOD=2s" \
    k6 run \
      --out "json=/scripts/.results_${name}.json" \
      "/scripts/${script}" \
    && pass "$name PASSED" \
    || { fail "$name FAILED"; }

  # Copy k6 JSON result out of the volume if it exists
  local result_src="$SCRIPT_DIR/k6/.results_${name}.json"
  [ -f "$result_src" ] && mv "$result_src" "$RESULTS_DIR/${name}.json" || true

  echo ""
}

case "$SCENARIO" in
  coldstart) run_scenario coldstart coldstart.js ;;
  load)      run_scenario load      load.js      ;;
  storm)     run_scenario storm     storm.js      ;;
  soak)      run_scenario soak      soak.js       ;;
  "")
    run_scenario coldstart coldstart.js
    run_scenario load      load.js
    run_scenario storm     storm.js
    # soak runs 5min+ so skip by default; opt-in with --scenario=soak
    info "Skipping soak (5 min). Run with --scenario=soak to include."
    ;;
  *) fail "Unknown scenario: $SCENARIO (valid: coldstart, load, storm, soak)" ;;
esac

header "Done"
pass "All requested scenarios completed"
info "Results saved to: $RESULTS_DIR"
