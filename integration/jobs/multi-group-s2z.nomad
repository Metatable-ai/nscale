job "multi-group-s2z" {
  datacenters = ["dc1"]
  type        = "service"

  # Two independent task groups in a single job. Each group registers its own
  # Consul service and Traefik router, so nscale must scale each group to zero
  # and wake it on demand independently of the other.

  group "alpha" {
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
        args    = ["-c", "mkdir -p /tmp/mg-alpha-www && echo 'alpha ok' > /tmp/mg-alpha-www/index.html"]
      }
      resources {
        cpu    = 1
        memory = 10
      }
    }

    task "web" {
      driver = "raw_exec"

      config {
        command = "/bin/busybox"
        args    = ["httpd", "-f", "-p", "${NOMAD_PORT_http}", "-h", "/tmp/mg-alpha-www"]
      }

      resources {
        cpu    = 1
        memory = 16
      }

      service {
        name         = "mg-alpha"
        provider     = "consul"
        port         = "http"
        address_mode = "host"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.mg-alpha.rule=Host(`mg-alpha.localhost`)",
          "traefik.http.routers.mg-alpha.entryPoints=http,https",
          "traefik.http.routers.mg-alpha.tls=true",
          "traefik.http.routers.mg-alpha.service=s2z-nscale@file",
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

  group "beta" {
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
        args    = ["-c", "mkdir -p /tmp/mg-beta-www && echo 'beta ok' > /tmp/mg-beta-www/index.html"]
      }
      resources {
        cpu    = 1
        memory = 10
      }
    }

    task "web" {
      driver = "raw_exec"

      config {
        command = "/bin/busybox"
        args    = ["httpd", "-f", "-p", "${NOMAD_PORT_http}", "-h", "/tmp/mg-beta-www"]
      }

      resources {
        cpu    = 1
        memory = 16
      }

      service {
        name         = "mg-beta"
        provider     = "consul"
        port         = "http"
        address_mode = "host"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.mg-beta.rule=Host(`mg-beta.localhost`)",
          "traefik.http.routers.mg-beta.entryPoints=http,https",
          "traefik.http.routers.mg-beta.tls=true",
          "traefik.http.routers.mg-beta.service=s2z-nscale@file",
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
