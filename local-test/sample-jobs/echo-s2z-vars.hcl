// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0

variable "service_name" {
  type    = string
  default = "echo-s2z-vars"
}

variable "host" {
  type    = string
  default = "echo-s2z-vars.localhost"
}

variable "image" {
  type    = string
  default = "hashicorp/http-echo"
}

variable "response_text" {
  type    = string
  default = "Hello from scale-to-zero service (vars)!"
}

variable "idle_timeout" {
  type    = string
  default = "20"
}

variable "job_spec_kv" {
  type    = string
  default = "scale-to-zero/jobs/echo-s2z-vars"
}

job "echo-s2z-vars" {
  datacenters = ["dc1"]
  type        = "service"

  # Scale-to-zero metadata
  meta = {
    "scale-to-zero.enabled"      = "true"
    "scale-to-zero.idle-timeout" = var.idle_timeout
    "scale-to-zero.job-spec-kv"  = var.job_spec_kv
  }

  group "main" {
    count = 1

    network {
      mode = "host"
      port "http" {}
    }

    task "echo" {
      driver = "docker"

      config {
        image = var.image
        args  = ["-listen=:${NOMAD_PORT_http}", "-text=${var.response_text}"]
        ports = ["http"]
      }

      resources {
        cpu    = 2
        memory = 16
      }

      service {
        name         = var.service_name
        provider     = "consul"
        port         = "http"
        address_mode = "host"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.echo-s2z-vars.rule=Host(`${var.host}`)",
          "traefik.http.routers.echo-s2z-vars.entryPoints=http",
          "traefik.http.middlewares.scalewaker-echo-s2z-vars.plugin.scalewaker.serviceName=${var.service_name}",
          "traefik.http.middlewares.scalewaker-echo-s2z-vars.plugin.scalewaker.timeout=30s",
          "traefik.http.routers.echo-s2z-vars.middlewares=scalewaker-echo-s2z-vars",
        ]

        check {
          type     = "http"
          path     = "/"
          interval = "1s"
          timeout  = "1s"
        }
      }
    }
  }
}
