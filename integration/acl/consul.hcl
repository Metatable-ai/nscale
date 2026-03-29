# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

datacenter = "dc1"
data_dir   = "/consul/data"
bind_addr  = "0.0.0.0"
client_addr = "0.0.0.0"
server     = true
bootstrap_expect = 1

acl {
  enabled                  = true
  default_policy           = "deny"
  enable_token_persistence = true
}

performance {
  leave_drain_time = "5s"
}
