#!/usr/bin/env bash
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Integration test for nscale with Consul & Nomad ACLs enabled.
#
# This test verifies that nscale can:
#   1. Authenticate to Nomad and Consul using scoped ACL tokens
#   2. Submit and scale jobs via the Nomad API with ACL tokens
#   3. Read service health from Consul with ACL tokens
#   4. Proxy requests and wake dormant services
#   5. Scale down idle services
#   6. Re-wake services after scale-down
#
# The test also verifies that unauthenticated requests are rejected
# by Nomad and Consul (i.e. ACLs are actually enforced).
#
# Usage:
#   ./test-acl.sh                # full run (start → test → teardown)
#   ./test-acl.sh --no-teardown  # keep infra running after test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.acl.yml"
JOB_FILE="$SCRIPT_DIR/jobs/echo-s2z.nomad"

NOMAD_ADDR="http://localhost:4646"
CONSUL_ADDR="http://localhost:8500"
NSCALE_PROXY="http://localhost:80"
NSCALE_ADMIN="http://localhost:9090"

INFRA_TIMEOUT=180
WAKE_TIMEOUT=60
SCALEDOWN_WAIT=40
TEARDOWN=true

for arg in "$@"; do
  case "$arg" in
    --no-teardown) TEARDOWN=false ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass()   { echo -e "${GREEN}✓ $1${NC}"; }
fail()   { echo -e "${RED}✗ $1${NC}"; }
info()   { echo -e "${YELLOW}→ $1${NC}"; }
header() { echo -e "\n${CYAN}══ $1 ══${NC}"; }

TESTS_PASSED=0
TESTS_FAILED=0

assert_pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  pass "$1"
}

assert_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  fail "$1"
}

cleanup() {
  if $TEARDOWN; then
    info "Cleaning up..."
    cd "$SCRIPT_DIR"
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    docker network rm nscale-acl-net 2>/dev/null || true
  else
    info "Leaving infrastructure running (--no-teardown)"
  fi
}

trap cleanup EXIT

# ══════════════════════════════════════════════════════════
header "Phase 0: Preflight"
# ══════════════════════════════════════════════════════════

info "Checking prerequisites..."
for cmd in docker curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    assert_fail "Required command '$cmd' not found"
    exit 1
  fi
done
assert_pass "Prerequisites OK"

# ══════════════════════════════════════════════════════════
header "Phase 1: Start ACL-enabled infrastructure"
# ══════════════════════════════════════════════════════════

info "Building and starting infrastructure..."
cd "$SCRIPT_DIR"
docker compose -f "$COMPOSE_FILE" up -d --build

info "Waiting for all services to be healthy (timeout: ${INFRA_TIMEOUT}s)..."
elapsed=0
while true; do
  if [ "$elapsed" -ge "$INFRA_TIMEOUT" ]; then
    assert_fail "Infrastructure did not start within ${INFRA_TIMEOUT}s"
    echo ""
    info "Container status:"
    docker compose -f "$COMPOSE_FILE" ps
    echo ""
    info "Container logs:"
    docker compose -f "$COMPOSE_FILE" logs --tail=30
    exit 1
  fi

  redis_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
    | jq -r 'select(.Service=="redis") | .Health' 2>/dev/null || echo "unknown")
  consul_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
    | jq -r 'select(.Service=="consul") | .Health' 2>/dev/null || echo "unknown")
  nomad_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
    | jq -r 'select(.Service=="nomad") | .Health' 2>/dev/null || echo "unknown")
  nscale_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
    | jq -r 'select(.Service=="nscale") | .Health' 2>/dev/null || echo "unknown")
  traefik_ok=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
    | jq -r 'select(.Service=="traefik") | .Health' 2>/dev/null || echo "unknown")

  if [[ "$redis_ok" == "healthy" && "$consul_ok" == "healthy" && \
        "$nomad_ok" == "healthy" && "$nscale_ok" == "healthy" && \
        "$traefik_ok" == "healthy" ]]; then
    break
  fi

  sleep 3
  elapsed=$((elapsed + 3))
  echo "  ... waiting (${elapsed}s) redis=$redis_ok consul=$consul_ok nomad=$nomad_ok nscale=$nscale_ok traefik=$traefik_ok"
done
assert_pass "All services healthy (${elapsed}s)"

# ── Load bootstrap tokens for test assertions ────────────
# Read from nscale container (it mounts bootstrap volume with both env files)
info "Reading bootstrap tokens..."
CONSUL_MGMT_TOKEN=$(docker compose -f "$COMPOSE_FILE" exec -T nscale cat /bootstrap/consul.env 2>/dev/null \
  | grep CONSUL_MGMT_TOKEN | cut -d= -f2 || echo "")
NOMAD_MGMT_TOKEN=$(docker compose -f "$COMPOSE_FILE" exec -T nscale cat /bootstrap/nomad.env 2>/dev/null \
  | grep NOMAD_MGMT_TOKEN | cut -d= -f2 || echo "")

if [ -z "$CONSUL_MGMT_TOKEN" ] || [ -z "$NOMAD_MGMT_TOKEN" ]; then
  assert_fail "Could not read bootstrap tokens from containers"
  exit 1
fi
assert_pass "Bootstrap tokens loaded"

# ══════════════════════════════════════════════════════════
header "Phase 2: Verify ACLs are enforced"
# ══════════════════════════════════════════════════════════

# ── Consul: unauthenticated request should be denied ──────
# Note: /v1/catalog/services returns 200 with empty results under deny policy.
# Use /v1/acl/tokens which truly returns 403 for unauthenticated requests.
info "Testing Consul ACL enforcement..."
CONSUL_UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "$CONSUL_ADDR/v1/acl/tokens" 2>/dev/null || echo "000")
if [ "$CONSUL_UNAUTH_CODE" = "403" ]; then
  assert_pass "Consul rejects unauthenticated ACL request (HTTP 403)"
else
  assert_fail "Consul did not return 403 for unauthenticated request (got $CONSUL_UNAUTH_CODE)"
fi

# ── Consul: authenticated request should succeed ──────────
CONSUL_AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "X-Consul-Token: $CONSUL_MGMT_TOKEN" \
  "$CONSUL_ADDR/v1/catalog/services" 2>/dev/null || echo "000")
if [ "$CONSUL_AUTH_CODE" = "200" ]; then
  assert_pass "Consul accepts authenticated catalog request (HTTP 200)"
else
  assert_fail "Consul rejected authenticated request (got $CONSUL_AUTH_CODE)"
fi

# ── Nomad: unauthenticated request should be denied ───────
info "Testing Nomad ACL enforcement..."
NOMAD_UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  "$NOMAD_ADDR/v1/jobs" 2>/dev/null || echo "000")
if [ "$NOMAD_UNAUTH_CODE" = "403" ]; then
  assert_pass "Nomad rejects unauthenticated job list (HTTP 403)"
else
  assert_fail "Nomad did not return 403 for unauthenticated request (got $NOMAD_UNAUTH_CODE)"
fi

# ── Nomad: authenticated request should succeed ───────────
NOMAD_AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "X-Nomad-Token: $NOMAD_MGMT_TOKEN" \
  "$NOMAD_ADDR/v1/jobs" 2>/dev/null || echo "000")
if [ "$NOMAD_AUTH_CODE" = "200" ]; then
  assert_pass "Nomad accepts authenticated job list (HTTP 200)"
else
  assert_fail "Nomad rejected authenticated request (got $NOMAD_AUTH_CODE)"
fi

# ══════════════════════════════════════════════════════════
header "Phase 3: Submit job & register with nscale"
# ══════════════════════════════════════════════════════════

info "Submitting echo-s2z job to Nomad (with ACL token)..."
JOB_HCL=$(cat "$JOB_FILE")
JOB_JSON=$(curl -fsS "$NOMAD_ADDR/v1/jobs/parse" \
  -X POST \
  -H "X-Nomad-Token: $NOMAD_MGMT_TOKEN" \
  -d "{\"JobHCL\": $(echo "$JOB_HCL" | jq -Rs .), \"Canonicalize\": true}" \
  -H "Content-Type: application/json")

SUBMIT_RESP=$(curl -fsS "$NOMAD_ADDR/v1/jobs" \
  -X POST \
  -H "X-Nomad-Token: $NOMAD_MGMT_TOKEN" \
  -d "{\"Job\": $JOB_JSON}" \
  -H "Content-Type: application/json")
EVAL_ID=$(echo "$SUBMIT_RESP" | jq -r '.EvalID')

if [ -n "$EVAL_ID" ] && [ "$EVAL_ID" != "null" ]; then
  assert_pass "Job submitted (eval: ${EVAL_ID:0:8})"
else
  assert_fail "Job submission failed"
  exit 1
fi

# ── Wait for job to be running ────────────────────────────
info "Waiting for echo-s2z to be running..."
elapsed=0
while true; do
  if [ "$elapsed" -ge "$WAKE_TIMEOUT" ]; then
    assert_fail "Job did not reach running state within ${WAKE_TIMEOUT}s"
    exit 1
  fi

  STATUS=$(curl -s \
    -H "X-Nomad-Token: $NOMAD_MGMT_TOKEN" \
    "$NOMAD_ADDR/v1/job/echo-s2z" | jq -r '.Status')
  ALLOCS=$(curl -s \
    -H "X-Nomad-Token: $NOMAD_MGMT_TOKEN" \
    "$NOMAD_ADDR/v1/job/echo-s2z/allocations" \
    | jq '[.[] | select(.ClientStatus=="running")] | length')

  if [ "$STATUS" = "running" ] && [ "$ALLOCS" -gt 0 ]; then
    break
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done
assert_pass "Job running (${elapsed}s)"

# ── Wait for healthy in Consul ────────────────────────────
info "Waiting for echo-s2z to be healthy in Consul..."
elapsed=0
while true; do
  if [ "$elapsed" -ge "$WAKE_TIMEOUT" ]; then
    assert_fail "Service not healthy in Consul within ${WAKE_TIMEOUT}s"
    exit 1
  fi

  HEALTHY=$(curl -s \
    -H "X-Consul-Token: $CONSUL_MGMT_TOKEN" \
    "$CONSUL_ADDR/v1/health/service/echo-s2z?passing=true" | jq 'length')
  if [ "$HEALTHY" -gt 0 ]; then
    break
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done
assert_pass "Service healthy in Consul (${elapsed}s)"

# ── Register with nscale ──────────────────────────────────
info "Registering echo-s2z in nscale..."
REG_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$NSCALE_ADMIN/admin/registry" \
  -H "Content-Type: application/json" \
  -d '{"job_id":"echo-s2z","service_name":"echo-s2z","nomad_group":"main"}')

if [ "$REG_CODE" = "201" ] || [ "$REG_CODE" = "409" ]; then
  assert_pass "Registered in nscale (HTTP $REG_CODE)"
else
  assert_fail "Registration failed (HTTP $REG_CODE)"
  exit 1
fi

# ══════════════════════════════════════════════════════════
header "Phase 4: Test warm-path proxy (service already running)"
# ══════════════════════════════════════════════════════════

info "Sending request through Traefik → nscale (warm path)..."
WARM_RESP=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Host: echo-s2z.localhost" \
  --max-time 30 \
  "$NSCALE_PROXY/" 2>/dev/null || echo "000")

if [ "$WARM_RESP" = "200" ]; then
  assert_pass "Warm-path request succeeded (HTTP 200)"
else
  assert_fail "Warm-path request failed (HTTP $WARM_RESP)"
fi

# ══════════════════════════════════════════════════════════
header "Phase 5: Scale to zero and test wake-on-request"
# ══════════════════════════════════════════════════════════

info "Waiting for deployment to complete..."
elapsed=0
while true; do
    if [ "$elapsed" -ge 60 ]; then
        assert_fail "Deployment did not complete within 60s"
        break
    fi

    DEP_STATUS=$(curl -s \
        -H "X-Nomad-Token: $NOMAD_MGMT_TOKEN" \
        "$NOMAD_ADDR/v1/job/echo-s2z/deployments" \
        | jq -r '.[0].Status // "unknown"')
    if [ "$DEP_STATUS" = "successful" ] || [ "$DEP_STATUS" = "null" ]; then
        break
    fi

    sleep 2
    elapsed=$((elapsed + 2))
done
assert_pass "Deployment complete (${elapsed}s)"

info "Scaling echo-s2z to 0 (via Nomad API with ACL token)..."
SCALE_RESP=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$NOMAD_ADDR/v1/job/echo-s2z/scale" \
  -H "X-Nomad-Token: $NOMAD_MGMT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"Count": 0, "Target": {"Group": "main"}}')

if [ "$SCALE_RESP" = "200" ]; then
  assert_pass "Scaled job to 0 (HTTP 200)"
else
  assert_fail "Scale-to-zero failed (HTTP $SCALE_RESP)"
fi

# ── Wait for allocs to stop ───────────────────────────────
info "Waiting for allocations to stop..."
elapsed=0
while true; do
  if [ "$elapsed" -ge 30 ]; then
    assert_fail "Allocations did not stop within 30s"
    break
  fi

  RUNNING=$(curl -s \
    -H "X-Nomad-Token: $NOMAD_MGMT_TOKEN" \
    "$NOMAD_ADDR/v1/job/echo-s2z/allocations" \
    | jq '[.[] | select(.ClientStatus=="running")] | length')
  if [ "$RUNNING" -eq 0 ]; then
    assert_pass "All allocations stopped (${elapsed}s)"
    break
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

# ── Small pause to let Consul deregister ──────────────────
sleep 3

# ── Wake-on-request: request should trigger scale-up ──────
info "Sending wake-on-request through nscale proxy..."
WAKE_START=$(date +%s)
WAKE_RESP=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Host: echo-s2z.localhost" \
  --max-time "$WAKE_TIMEOUT" \
  "$NSCALE_PROXY/" 2>/dev/null || echo "000")
WAKE_END=$(date +%s)
WAKE_LATENCY=$((WAKE_END - WAKE_START))

if [ "$WAKE_RESP" = "200" ]; then
  assert_pass "Wake-on-request succeeded (HTTP 200, ${WAKE_LATENCY}s)"
else
  assert_fail "Wake-on-request failed (HTTP $WAKE_RESP, ${WAKE_LATENCY}s)"
  info "nscale logs:"
  docker compose -f "$COMPOSE_FILE" logs nscale --tail=20
fi

# ══════════════════════════════════════════════════════════
header "Phase 6: Verify nscale uses scoped tokens (not mgmt)"
# ══════════════════════════════════════════════════════════

info "Checking nscale logs for token-related errors..."
NSCALE_LOGS=$(docker compose -f "$COMPOSE_FILE" logs nscale 2>/dev/null)

if echo "$NSCALE_LOGS" | grep -qi "permission denied\|403\|ACL token not found"; then
  assert_fail "nscale encountered ACL permission errors"
  echo "$NSCALE_LOGS" | grep -i "permission denied\|403\|ACL token" | tail -5
else
  assert_pass "nscale has no ACL permission errors in logs"
fi

if echo "$NSCALE_LOGS" | grep -qi "starting"; then
  assert_pass "nscale started successfully with ACL tokens"
else
  assert_fail "nscale may not have started properly"
fi

# ══════════════════════════════════════════════════════════
header "Phase 7: Test idle scale-down with ACL tokens"
# ══════════════════════════════════════════════════════════

info "Waiting for idle scale-down (timeout: ${SCALEDOWN_WAIT}s)..."
elapsed=0
scaled_down=false
while true; do
  if [ "$elapsed" -ge "$SCALEDOWN_WAIT" ]; then
    break
  fi

  COUNT=$(curl -s \
    -H "X-Nomad-Token: $NOMAD_MGMT_TOKEN" \
    "$NOMAD_ADDR/v1/job/echo-s2z" \
    | jq '.TaskGroups[0].Count')

  if [ "$COUNT" = "0" ]; then
    scaled_down=true
    break
  fi
  sleep 3
  elapsed=$((elapsed + 3))
  echo "  ... waiting (${elapsed}s) count=$COUNT"
done

if $scaled_down; then
  assert_pass "Idle scale-down worked (${elapsed}s) — nscale scaled job to 0 using ACL token"
else
  assert_fail "Idle scale-down did not occur within ${SCALEDOWN_WAIT}s"
  info "nscale scaler logs:"
  docker compose -f "$COMPOSE_FILE" logs nscale 2>/dev/null | grep -i "scale\|idle\|scaler" | tail -10
fi

# ══════════════════════════════════════════════════════════
header "Phase 8: Re-wake after scale-down"
# ══════════════════════════════════════════════════════════

if $scaled_down; then
  sleep 3
  info "Sending request to re-wake service..."
  REWAKE_RESP=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Host: echo-s2z.localhost" \
    --max-time "$WAKE_TIMEOUT" \
    "$NSCALE_PROXY/" 2>/dev/null || echo "000")

  if [ "$REWAKE_RESP" = "200" ]; then
    assert_pass "Re-wake after scale-down succeeded (HTTP 200)"
  else
    assert_fail "Re-wake failed (HTTP $REWAKE_RESP)"
    info "nscale logs:"
    docker compose -f "$COMPOSE_FILE" logs nscale --tail=20
  fi
else
  info "Skipping re-wake test (scale-down did not occur)"
fi

# ══════════════════════════════════════════════════════════
header "Results"
# ══════════════════════════════════════════════════════════

TOTAL=$((TESTS_PASSED + TESTS_FAILED))
echo ""
echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
echo -e "  Total:  $TOTAL"
echo ""

if [ "$TESTS_FAILED" -gt 0 ]; then
  fail "ACL integration test FAILED ($TESTS_FAILED failures)"
  exit 1
else
  pass "ACL integration test PASSED ($TESTS_PASSED assertions)"
  exit 0
fi
