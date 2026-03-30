#!/usr/bin/env bash
# multi-job.sh — Submit and register N echo jobs for multi-service stress testing.
#
# Usage:
#   ./scripts/multi-job.sh submit 50              # submit + register 50 fast jobs
#   ./scripts/multi-job.sh submit 50 --slow-pct 30 # 30% of jobs get CGI /cgi-bin/slow?delay=N
#   ./scripts/multi-job.sh status 50              # check running status of all 50
#   ./scripts/multi-job.sh teardown 50            # stop and purge all 50 jobs
set -euo pipefail

ACTION="${1:?Usage: multi-job.sh <submit|status|teardown> <count> [--slow-pct N]}"
COUNT="${2:-50}"

# Parse optional --slow-pct flag
SLOW_PCT=0
shift 2 || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slow-pct) SLOW_PCT="${2:-0}"; shift 2 ;;
    *) shift ;;
  esac
done

NOMAD_ADDR="${NOMAD_ADDR:-http://localhost:4646}"
NSCALE_ADDR="${NSCALE_ADDR:-http://localhost:9090}"

job_name() { printf "echo-%03d" "$1"; }

# Determine if a job index should be slow (CGI-enabled).
# Uses deterministic assignment: first N% of jobs are slow.
is_slow_job() {
  local idx=$1
  local slow_count=$(( (COUNT * SLOW_PCT + 99) / 100 ))
  [[ "$idx" -le "$slow_count" ]]
}

# Generate a fast echo-only job.
generate_fast_job_hcl() {
  local name=$1
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
          "traefik.http.routers.${name}.service=s2z-nscale@file",
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

# Generate a slow CGI job (has /cgi-bin/slow?delay=N plus normal index).
# Uses the same pattern as jobs/slow-service.nomad.
generate_slow_job_hcl() {
  local name=$1
  local dir="/tmp/${name}-www"
  cat <<HCLEOF
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
        args    = ["-c", <<EOT
mkdir -p ${dir}/cgi-bin
echo 'Hello from ${name}!' > ${dir}/index.html
cat > ${dir}/cgi-bin/slow << 'CGI'
#!/bin/sh
DELAY=\$(echo "\$QUERY_STRING" | sed -n 's/.*delay=\([0-9]*\).*/\1/p')
[ -z "\$DELAY" ] && DELAY=0
[ "\$DELAY" -gt 0 ] 2>/dev/null && sleep "\$DELAY"
printf "Content-Type: text/plain\r\n\r\nDone after %ss delay\n" "\$DELAY"
CGI
chmod +x ${dir}/cgi-bin/slow
EOT
        ]
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
        args    = ["httpd", "-f", "-p", "\${NOMAD_PORT_http}", "-h", "${dir}"]
      }

      resources {
        cpu    = 10
        memory = 32
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
          "traefik.http.routers.${name}.service=s2z-nscale@file",
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
HCLEOF
}

do_submit() {
  local slow_count=$(( (COUNT * SLOW_PCT + 99) / 100 ))
  echo "==> Submitting ${COUNT} jobs (${slow_count} slow, $((COUNT - slow_count)) fast)..."
  local ok=0 fail=0

  for i in $(seq 1 "$COUNT"); do
    local name
    name=$(job_name "$i")
    local tmpfile="/tmp/${name}.nomad"

    if is_slow_job "$i"; then
      generate_slow_job_hcl "$name" > "$tmpfile"
    else
      generate_fast_job_hcl "$name" > "$tmpfile"
    fi

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
      -d "{\"job_id\":\"${name}\",\"service_name\":\"${name}\",\"endpoint\":\"http://${name}.localhost\",\"nomad_group\":\"main\"}")
    if [[ "$resp" == "201" || "$resp" == "200" ]]; then
      ((ok++))
    else
      echo "  FAIL register ${name}: HTTP ${resp}"
      ((fail++))
    fi
  done
  echo "==> Registered: ${ok} ok, ${fail} failed"
  echo "==> Slow jobs (indices 1..${slow_count}): echo-001 .. $(job_name "$slow_count")"
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
