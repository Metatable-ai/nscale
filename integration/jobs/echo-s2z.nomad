job "echo-s2z" {
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
        args    = ["-c", "mkdir -p /tmp/echo-www && echo 'Hello from scale-to-zero echo service!' > /tmp/echo-www/index.html"]
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
        args    = ["httpd", "-f", "-p", "${NOMAD_PORT_http}", "-h", "/tmp/echo-www"]
      }

      resources {
        cpu    = 1
        memory = 16
      }

      service {
        name         = "echo-s2z"
        provider     = "consul"
        port         = "http"
        address_mode = "host"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.echo-s2z.rule=Host(`echo-s2z.localhost`)",
          "traefik.http.routers.echo-s2z.entryPoints=http,https",
          "traefik.http.routers.echo-s2z.tls=true",
          "traefik.http.routers.echo-s2z.service=s2z-nscale@file",
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
