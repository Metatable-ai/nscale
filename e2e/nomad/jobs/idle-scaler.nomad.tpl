# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

job "idle-scaler-e2e" {
  datacenters = ["dc1"]
  type        = "system"

  group "main" {
    task "idle-scaler" {
      driver = "docker"

      config {
        image   = "nomad-scale-to-zero-e2e:latest"
        command = "/app/bin/idle-scaler"
        force_pull = false
      }

      env {
        NOMAD_ADDR           = "http://nomad:4646"
        CONSUL_ADDR          = "http://consul:8500"
        REDIS_ADDR           = "redis:6379"
        REDIS_PASSWORD       = ""
        STORE_TYPE           = "${E2E_STORE_TYPE}"
        IDLE_CHECK_INTERVAL  = "${E2E_IDLE_CHECK_INTERVAL}"
        DEFAULT_IDLE_TIMEOUT = "${E2E_IDLE_TIMEOUT}"
        PURGE_ON_SCALEDOWN   = "false"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}