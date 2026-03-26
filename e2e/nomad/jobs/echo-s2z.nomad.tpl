# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

job "${E2E_RENDER_JOB_NAME}" {
  datacenters = ["dc1"]
  type        = "service"

  meta = {
    "scale-to-zero.enabled"      = "true"
    "scale-to-zero.idle-timeout" = "${E2E_RENDER_IDLE_TIMEOUT}"
    "scale-to-zero.job-spec-kv"  = "${E2E_RENDER_JOB_SPEC_KEY}"
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
        E2E_ECHO_TEXT = "Hello from ${E2E_RENDER_SERVICE_NAME}"
      }

      resources {
        cpu    = 50
        memory = 64
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
          "traefik.http.routers.${E2E_RENDER_SERVICE_NAME}.middlewares=scalewaker-${E2E_RENDER_SERVICE_NAME}",
        ]

        check {
          type     = "http"
          path     = "/"
          interval = "2s"
          timeout  = "2s"
        }
      }
    }
  }
}