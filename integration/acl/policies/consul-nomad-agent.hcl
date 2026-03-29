# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Consul ACL policy for the Nomad agent.
# Allows Nomad to register/deregister services, manage sessions, etc.

agent_prefix "" {
  policy = "read"
}

node_prefix "" {
  policy = "write"
}

service_prefix "" {
  policy = "write"
}

session_prefix "" {
  policy = "write"
}
