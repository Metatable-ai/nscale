# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Consul ACL policy for nscale (scale-to-zero operations).
# Allows reading nodes, writing to KV under scale-to-zero/,
# and reading/writing services for health checks and discovery.

node_prefix "" {
  policy = "read"
}

key_prefix "scale-to-zero/" {
  policy = "write"
}

service_prefix "" {
  policy = "read"
}
