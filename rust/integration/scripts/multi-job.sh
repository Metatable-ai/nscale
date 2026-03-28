#!/usr/bin/env bash
# multi-job.sh — Submit and register N echo jobs for multi-service stress testing.
#
# Usage:
#   ./scripts/multi-job.sh submit 50    # submit + register 50 jobs
#   ./scripts/multi-job.sh status 50    # check running status of all 50
#   ./scripts/multi-job.sh teardown 50  # stop and purge all 50 jobs
set -euo pipefail

ACTION="${1:?Usage: multi-job.sh <submit|status|teardown> <count>}"
COUNT="${2:-50}"

NOMAD_ADDR="${NOMAD_ADDR:-http://localhost:4646}"
NSCALE_ADDR="${NSCALE_ADDR:-http://localhost:9090}"

job_name() { printf "echo-%03d" "$1"; }

generate_job_hcl() {
  local idx=$1
  local name
  name=$(job_name "$idx")
  cat <<EOF
job "${name}" {
  datacenters = ["dc1"]
  type        = "service"

  group "main" {
    count = 1

    network {
      mode = "host"
      port "http" {}
    }

    task "setup" {
      driver = "raw_exec"
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }
      config {
        command = "/bin/sh"
        args    = ["-c", "mkdir -p /tmp/${name}-www && echo 'Hello from ${name}!' > /tmp/${name}-www/index.html"]
      }
      resources {
        cpu    = 1
        memory = 10
      }
    }

    task "echo" {
      driver = "raw_exec"

      config {
        command = "/bin/busybox"
        args    = ["httpd", "-f", "-p", "\${NOMAD_PORT_http}", "-h", "/tmp/${name}-www"]
      }

      resources {
        cpu    = 1
        memory = 16
      }

      service {
        name         = "${name}"
        provider     = "consul"
        port         = "http"
        address_mode = "host"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.${name}.rule=Host(\`${name}.localhost\`)",
          "traefik.http.routers.${name}.entryPoints=http",
          "traefik.http.routers.${name}.middlewares=s2z-error-fallback@file",
        ]

        check {
          type     = "http"
          path     = "/"
          interval = "2s"
          timeout  = "1s"
        }
      }
    }
  }
}
EOF
}

do_submit() {
  echo "==> Submitting ${COUNT} jobs..."
  local ok=0 fail=0

  for i in $(seq 1 "$COUNT"); do
    local name
    name=$(job_name "$i")
    local tmpfile="/tmp/${name}.nomad"
    generate_job_hcl "$i" > "$tmpfile"

    # Copy into Nomad container and run
    docker cp "$tmpfile" integration-nomad-1:/tmp/"${name}.nomad" 2>/dev/null
    if docker exec integration-nomad-1 nomad job run -detach "/tmp/${name}.nomad" >/dev/null 2>&1; then
      ((ok++))
    else
      echo "  FAIL: ${name}"
      ((fail++))
    fi
    rm -f "$tmpfile"

    # Progress every 10
    if (( i % 10 == 0 )); then
      echo "  submitted ${i}/${COUNT}..."
    fi
  done
  echo "==> Submitted: ${ok} ok, ${fail} failed"

  echo "==> Waiting 15s for jobs to become healthy..."
  sleep 15

  echo "==> Registering ${COUNT} jobs with nscale..."
  ok=0 fail=0
  for i in $(seq 1 "$COUNT"); do
    local name
    name=$(job_name "$i")
    local resp
    resp=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${NSCALE_ADDR}/admin/registry" \
      -H 'Content-Type: application/json' \
      -d "{\"job_id\":\"${name}\",\"service_name\":\"${name}\",\"host\":\"${name}.localhost\",\"nomad_group\":\"main\"}")
    if [[ "$resp" == "201" || "$resp" == "200" ]]; then
      ((ok++))
    else
      echo "  FAIL register ${name}: HTTP ${resp}"
      ((fail++))
    fi
  done
  echo "==> Registered: ${ok} ok, ${fail} failed"
}

do_status() {
  local running=0 stopped=0 missing=0
  for i in $(seq 1 "$COUNT"); do
    local name
    name=$(job_name "$i")
    local count
    count=$(curl -s "${NOMAD_ADDR}/v1/job/${name}/scale" 2>/dev/null | jq -r '.TaskGroups.main.Running // 0' 2>/dev/null || echo "0")
    if [[ "$count" == "null" ]] || [[ -z "$count" ]]; then
      ((missing++))
    elif (( count > 0 )); then
      ((running++))
    else
      ((stopped++))
    fi
  done
  echo "Running: ${running}  Stopped: ${stopped}  Missing: ${missing}  Total: ${COUNT}"
}

do_teardown() {
  echo "==> Tearing down ${COUNT} jobs..."
  for i in $(seq 1 "$COUNT"); do
    local name
    name=$(job_name "$i")
    docker exec integration-nomad-1 nomad job stop -purge "${name}" >/dev/null 2>&1 || true
  done
  echo "==> Done"
}

case "$ACTION" in
  submit)   do_submit ;;
  status)   do_status ;;
  teardown) do_teardown ;;
  *) echo "Unknown action: $ACTION"; exit 1 ;;
esac
