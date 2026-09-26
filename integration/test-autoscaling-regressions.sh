#!/usr/bin/env bash
# Destructive only to this disposable Compose project. Requires free integration
# ports and no other stack on nscale-net. NSCALE_SKIP_BUILD=1 reuses a built image.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT=nscale-fix
COMPOSE=(docker compose -p "$PROJECT" -f "$SCRIPT_DIR/docker-compose.yml" -f "$SCRIPT_DIR/docker-compose.autoscale-regressions.yml")
ARTIFACTS=$(mktemp -d)
NOMAD=http://localhost:4646
ADMIN=http://localhost:9090
JOB=autoscale-echo
SERVICE=autoscale-regression
cleanup() {
    local result=$?
    if [ "$result" -ne 0 ]; then "${COMPOSE[@]}" logs --tail=100 > "$ARTIFACTS/stack.log" 2>&1 || true; fi
    "${COMPOSE[@]}" down -v --remove-orphans > "$ARTIFACTS/cleanup.log" 2>&1 || true
    echo "Regression artifacts: $ARTIFACTS"
    return "$result"
}
# Never take over another project's fixed integration network.
if docker network inspect nscale-net >/dev/null 2>&1; then
    owner=$(docker network inspect nscale-net --format '{{index .Labels "com.docker.compose.project"}}')
    [ "$owner" = "$PROJECT" ] || { echo "nscale-net belongs to another stack: $owner"; exit 1; }
fi
trap cleanup EXIT
bash "$SCRIPT_DIR/traefik/certs/generate.sh"
if [ "${NSCALE_SKIP_BUILD:-0}" != 1 ]; then "${COMPOSE[@]}" build nscale; fi
"${COMPOSE[@]}" up -d --no-build --wait --wait-timeout 180
for _ in $(seq 1 60); do curl -fsS http://localhost:19091/readyz >/dev/null && break; sleep 1; done
curl -fsS http://localhost:19091/readyz >/dev/null

count() { curl -fsS "$NOMAD/v1/job/$JOB" | jq -r '.TaskGroups[0].Count'; }
request() { curl -fsS --max-time 60 -H "Host: $SERVICE.localhost" "http://localhost${1:-/cgi-bin/identity}"; }
wait_count() {
    for _ in $(seq 1 90); do [ "$(count)" = "$1" ] && return; sleep 1; done
    echo "Expected count $1; got $(count)"; exit 1
}
wait_healthy() {
    for _ in $(seq 1 90); do
        healthy=$(curl -fsS "http://localhost:8500/v1/health/service/$SERVICE?passing=true" | jq length)
        [ "$healthy" = "$1" ] && return
        sleep 1
    done
    echo "Expected $1 healthy instances; got $healthy"; exit 1
}
scale() {
    for _ in $(seq 1 60); do
        code=$(curl -sS -o "$ARTIFACTS/scale.json" -w '%{http_code}' -X POST "$NOMAD/v1/job/$JOB/scale" -d "{\"Count\":$1,\"Target\":{\"Group\":\"main\"},\"Message\":\"regression test\"}")
        [ "$code" = 200 ] && return
        sleep 1
    done
    cat "$ARTIFACTS/scale.json"; exit 1
}
register_policy() {
    jq --argjson policy "$1" '.managed_services[0] | .autoscaling=$policy' "$ARTIFACTS/submission.json" > "$ARTIFACTS/registration.json"
    curl -fsS -H 'Content-Type: application/json' -d @"$ARTIFACTS/registration.json" "$ADMIN/admin/registry" >/dev/null
}

# Start at zero: the first HTTP request must wake directly to min_count=3.
jq -n --rawfile hcl "$SCRIPT_DIR/jobs/autoscale-echo.nomad" \
  --arg vars "service_name = \"$SERVICE\"\nhost_name = \"$SERVICE.localhost\"" \
  '{hcl:($hcl|sub("count = 1";"count = 0")),variables:($vars|gsub("\\\\n";"\n")),autoscaling:{enabled:true,min_count:3,max_count:4,scale_to_zero:false,target_requests_per_second_per_instance:10,cooldown_secs:15}}' \
  > "$ARTIFACTS/submission-request.json"
curl -fsS -H 'Content-Type: application/json' -d @"$ARTIFACTS/submission-request.json" "$ADMIN/admin/jobs" > "$ARTIFACTS/submission.json"
request >/dev/null
wait_count 3
wait_healthy 3
register_policy '{"enabled":false,"min_count":3,"max_count":4,"scale_to_zero":false,"target_requests_per_second_per_instance":10}'
for _ in $(seq 1 30); do request; done > "$ARTIFACTS/identities.txt"
[ "$(awk '{print $1}' "$ARTIFACTS/identities.txt" | sort -u | wc -l | tr -d ' ')" = 3 ]
echo 'PASS: cold wake uses min_count and all three allocations receive traffic'

"${COMPOSE[@]}" restart nscale
for _ in $(seq 1 60); do curl -fsS "$ADMIN/readyz" >/dev/null && break; sleep 1; done
request >/dev/null
[ "$(count)" = 3 ]
echo 'PASS: proxy restart preserves the running replica count'

scale 4; wait_healthy 4
scale 3; wait_healthy 3
for _ in $(seq 1 10); do request >/dev/null; [ "$(count)" = 3 ]; sleep 1; done
echo 'PASS: 4 -> 3 stays at three after allocation-stop events and requests'

# Stream through the peer, then ask the other process to purge. Its local
# in-flight count is zero; Redis must protect the active response body.
curl -fsS -N --max-time 45 -H "Host: $SERVICE.localhost" http://localhost:18081/cgi-bin/stream > "$ARTIFACTS/stream.txt" &
stream_pid=$!
for _ in $(seq 1 30); do grep -q started "$ARTIFACTS/stream.txt" && break; sleep 1; done
grep -q started "$ARTIFACTS/stream.txt"
code=$(curl -sS -o "$ARTIFACTS/purge.json" -w '%{http_code}' -X DELETE "$ADMIN/admin/jobs/$JOB")
[ "$code" = 409 ]
wait "$stream_pid"
grep -q completed "$ARTIFACTS/stream.txt"
echo 'PASS: another proxy cannot purge a job while its response body is streaming'

# Exercise actual metric-driven decisions after the routing/lifecycle checks.
register_policy '{"enabled":true,"min_count":1,"max_count":3,"scale_to_zero":false,"scale_up_step":2,"scale_down_step":1,"cooldown_secs":15,"decision_window_secs":30,"target_requests_per_second_per_instance":1}'
scale 1; wait_healthy 1
end=$((SECONDS + 100))
while [ "$SECONDS" -lt "$end" ]; do request / >/dev/null; sleep 0.05; done
[ "$(count)" -ge 2 ] && [ "$(count)" -le 3 ]
for _ in $(seq 1 30); do request; done > "$ARTIFACTS/scaled-identities.txt"
[ "$(awk '{print $1}' "$ARTIFACTS/scaled-identities.txt" | sort -u | wc -l | tr -d ' ')" -ge 2 ]
wait_count 1
sleep 20
[ "$(count)" = 1 ]
echo 'PASS: measured traffic adds usable replicas, idle traffic returns to one, scale_to_zero=false is preserved'
