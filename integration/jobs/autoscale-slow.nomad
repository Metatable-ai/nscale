variable "service_name" {
  type = string
}

variable "host_name" {
  type = string
}

job "autoscale-slow" {
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
mkdir -p /tmp/autoscale-slow/cgi-bin
echo 'Hello from autoscale slow service!' > /tmp/autoscale-slow/index.html
cat > /tmp/autoscale-slow/cgi-bin/slow << 'CGI'
#!/bin/sh
DELAY=$(echo "$QUERY_STRING" | sed -n 's/.*delay=\([0-9]*\).*/\1/p')
[ -z "$DELAY" ] && DELAY=0
[ "$DELAY" -gt 0 ] 2>/dev/null && sleep "$DELAY"
printf "Content-Type: text/plain\r\n\r\nDone after %ss delay\n" "$DELAY"
CGI
chmod +x /tmp/autoscale-slow/cgi-bin/slow
EOT
        ]
      }
      resources {
        cpu    = 10
        memory = 16
      }
    }

    task "server" {
      driver = "raw_exec"

      config {
        command = "/bin/busybox"
        args    = ["httpd", "-f", "-p", "${NOMAD_PORT_http}", "-h", "/tmp/autoscale-slow"]
      }

      resources {
        cpu    = 10
        memory = 32
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
