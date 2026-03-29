# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

data_dir  = "/tmp/nomad"
bind_addr = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled       = true
  cpu_total_compute = 4000
  network_interface = "eth0"
  options = {
    "driver.raw_exec.enable"    = "1"
    "driver.raw_exec.no_cgroups" = "1"
    "driver.docker.enable"      = "1"
  }
}

acl {
  enabled = true
}

consul {
  address = "consul:8500"
}
