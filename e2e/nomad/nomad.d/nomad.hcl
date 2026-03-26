# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

data_dir  = "/tmp/nomad"
bind_addr = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
  network_interface = "eth0"
  cpu_total_compute = 2000
  memory_total_mb   = 2048
  disk_total_mb     = 524288
  disk_free_mb      = 262144
  options = {
    "driver.raw_exec.enable"      = "1"
    "driver.docker.enable"        = "1"
    "driver.raw_exec.no_cgroups"  = "1"
  }
}

plugin "docker" {
  config {
    allow_privileged = true
    volumes {
      enabled = true
    }
  }
}

consul {
  address = "consul:8500"
}

acl {
  enabled = false
}

ports {
  http = 4646
  rpc  = 4647
  serf = 4648
}