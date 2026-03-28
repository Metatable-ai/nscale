# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

job "${E2E_RENDER_JOB_NAME}" {
  datacenters = ["dc1"]
  type        = "service"

  meta = {
    "scale-to-zero.enabled"      = "true"
    "scale-to-zero.idle-timeout" = "${E2E_RENDER_IDLE_TIMEOUT}"
    "scale-to-zero.job-spec-kv"  = "${E2E_RENDER_JOB_SPEC_KEY}"
    "e2e.workload.class"         = "${E2E_RENDER_WORKLOAD_CLASS}"
    "e2e.workload.ordinal"       = "${E2E_RENDER_WORKLOAD_ORDINAL}"
    "e2e.workload.dependency"    = "${E2E_RENDER_DEPENDENCY_HOST}"
  }

  group "main" {
    count = 1

    network {
      mode = "host"
      port "http" {}
    }

    task "echo" {
      driver = "raw_exec"

      config {
        command = "/app/bin/e2e-echo"
      }

      env {
        E2E_ECHO_SERVICE_NAME       = "${E2E_RENDER_SERVICE_NAME}"
        E2E_ECHO_WORKLOAD_CLASS     = "${E2E_RENDER_WORKLOAD_CLASS}"
        E2E_ECHO_WORKLOAD_ORDINAL   = "${E2E_RENDER_WORKLOAD_ORDINAL}"
        E2E_ECHO_TEXT               = "${E2E_RENDER_RESPONSE_TEXT}"
        E2E_ECHO_RESPONSE_MODE      = "${E2E_RENDER_RESPONSE_MODE}"
        E2E_ECHO_STARTUP_DELAY      = "${E2E_RENDER_STARTUP_DELAY}"
        E2E_ECHO_HEALTH_MODE        = "${E2E_RENDER_HEALTH_MODE}"
        E2E_ECHO_IDLE_TIMEOUT       = "${E2E_RENDER_IDLE_TIMEOUT}"
        E2E_ECHO_DEPENDENCY_URL     = "${E2E_RENDER_DEPENDENCY_URL}"
        E2E_ECHO_DEPENDENCY_HOST    = "${E2E_RENDER_DEPENDENCY_HOST}"
        E2E_ECHO_DEPENDENCY_TIMEOUT = "${E2E_RENDER_DEPENDENCY_TIMEOUT}"
      }

      resources {
        cpu    = ${E2E_RENDER_JOB_CPU}
        memory = ${E2E_RENDER_JOB_MEMORY}
      }

      service {
        name         = "${E2E_RENDER_SERVICE_NAME}"
        provider     = "consul"
        port         = "http"
        address_mode = "host"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.${E2E_RENDER_SERVICE_NAME}.rule=Host(`${E2E_RENDER_HOST_NAME}`)",
          "traefik.http.routers.${E2E_RENDER_SERVICE_NAME}.entryPoints=http",
          "traefik.http.middlewares.scalewaker-${E2E_RENDER_SERVICE_NAME}.plugin.scalewaker.serviceName=${E2E_RENDER_SERVICE_NAME}",
          "traefik.http.middlewares.scalewaker-${E2E_RENDER_SERVICE_NAME}.plugin.scalewaker.timeout=45s",
          "traefik.http.middlewares.scalewaker-${E2E_RENDER_SERVICE_NAME}.plugin.scalewaker.probePath=/healthz",
          "traefik.http.routers.${E2E_RENDER_SERVICE_NAME}.middlewares=scalewaker-${E2E_RENDER_SERVICE_NAME}",
          "e2e.workload.class=${E2E_RENDER_WORKLOAD_CLASS}",
        ]

        check {
          type     = "http"
          path     = "${E2E_RENDER_JOB_CHECK_PATH}"
          interval = "${E2E_RENDER_JOB_CHECK_INTERVAL}"
          timeout  = "${E2E_RENDER_JOB_CHECK_TIMEOUT}"
        }
      }
    }
  }
}
