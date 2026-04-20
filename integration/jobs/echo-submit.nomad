variable "service_name" {
  type = string
}

variable "host_name" {
  type = string
}

job "echo-submit-job" {
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
        args    = ["-c", "mkdir -p /tmp/echo-submit-www && echo 'Hello from admin-submitted echo service!' > /tmp/echo-submit-www/index.html"]
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
        args    = ["httpd", "-f", "-p", "${NOMAD_PORT_http}", "-h", "/tmp/echo-submit-www"]
      }

      resources {
        cpu    = 1
        memory = 16
      }

      service {
        name         = var.service_name
        provider     = "consul"
        port         = "http"
        address_mode = "host"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.${var.service_name}.rule=Host(`${var.host_name}`)",
          "traefik.http.routers.${var.service_name}.entryPoints=http",
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
