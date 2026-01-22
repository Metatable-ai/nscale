job "echo-server" {
  datacenters = ["dc1"]
  type        = "service"

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
        args  = ["-listen=:${NOMAD_PORT_http}", "-text=Hello from echo-server"]
        ports = ["http"]
      }

      resources {
        cpu    = 2
        memory = 16
      }

      service {
        name         = "echo-server"
        provider     = "consul"
        port         = "http"
        address_mode = "host"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.echo.rule=Host(`echo.localhost`)",
          "traefik.http.routers.echo.entryPoints=http",
          "traefik.http.middlewares.echo.headers.accessControlAllowCredentials=true",
          "traefik.http.middlewares.echo.headers.accesscontrolallowmethods=*",
          "traefik.http.middlewares.echo.headers.accessControlExposeHeaders=*",
          "traefik.http.middlewares.echo.headers.accesscontrolallowheaders=*",
          "traefik.http.middlewares.echo.headers.accesscontrolalloworiginlist=*",
          "traefik.http.middlewares.echo.headers.accesscontrolmaxage=10",
          "traefik.http.middlewares.echo.headers.addvaryheader=true",
          "traefik.http.routers.echo.middlewares=echo",
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
