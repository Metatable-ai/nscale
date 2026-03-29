# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Nomad config template for ACL mode.
# ${CONSUL_NOMAD_AGENT_TOKEN} is substituted at bootstrap time.

acl {
  enabled = true
}

consul {
  address = "consul:8500"
  token   = "${CONSUL_NOMAD_AGENT_TOKEN}"
}

client {
  cpu_total_compute = 4000

  options = {
    "driver.raw_exec.enable"    = "1"
    "driver.raw_exec.no_cgroups" = "1"
    "driver.docker.enable"      = "1"
  }
}
