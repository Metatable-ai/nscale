job "idle-scaler" {
  datacenters = ["dc1"]
  type        = "system"

  group "main" {
    task "idle-scaler" {
      driver = "raw_exec"

      config {
        command = "/tmp/idle-scaler"
      }

      env {
        NOMAD_ADDR            = "http://127.0.0.1:4646"
        CONSUL_ADDR           = "http://127.0.0.1:8500"
        NOMAD_TOKEN           = ""
        CONSUL_TOKEN          = ""
        IDLE_CHECK_INTERVAL   = "30s"
        DEFAULT_IDLE_TIMEOUT  = "60s"
        PURGE_ON_SCALEDOWN    = "true"
        
        # Redis running in Docker, exposed on host port 6379
        REDIS_ADDR            = "127.0.0.1:6379"
        REDIS_PASSWORD        = ""
        STORE_TYPE            = "redis"
      }

      resources {
        cpu    = 2
        memory = 32
      }
    }
  }
}
