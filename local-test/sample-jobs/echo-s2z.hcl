job "echo-s2z" {
  datacenters = ["dc1"]
  type        = "service"

  # Scale-to-zero metadata
  meta = {
    "scale-to-zero.enabled"      = "true"
    "scale-to-zero.idle-timeout" = "20"
    "scale-to-zero.job-spec-kv"  = "scale-to-zero/jobs/echo-s2z"
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
        image = "hashicorp/http-echo"
        args  = ["-listen=:${NOMAD_PORT_http}", "-text=Hello from scale-to-zero service!"]
        ports = ["http"]
      }

      resources {
        cpu    = 2
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
          "traefik.http.routers.echo-s2z.entryPoints=http",
          "traefik.http.middlewares.echo-s2z.headers.accessControlAllowCredentials=true",
          "traefik.http.middlewares.echo-s2z.headers.accesscontrolallowmethods=*",
          "traefik.http.middlewares.echo-s2z.headers.accessControlExposeHeaders=*",
          "traefik.http.middlewares.echo-s2z.headers.accesscontrolallowheaders=*",
          "traefik.http.middlewares.echo-s2z.headers.accesscontrolalloworiginlist=*",
          "traefik.http.middlewares.echo-s2z.headers.accesscontrolmaxage=10",
          "traefik.http.middlewares.echo-s2z.headers.addvaryheader=true",
          "traefik.http.middlewares.scalewaker-echo.plugin.scalewaker.serviceName=echo-s2z",
          "traefik.http.middlewares.scalewaker-echo.plugin.scalewaker.timeout=30s",
          "traefik.http.routers.echo-s2z.middlewares=echo-s2z,scalewaker-echo",
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
