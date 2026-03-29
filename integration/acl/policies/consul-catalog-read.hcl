# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Consul ACL policy for Traefik's ConsulCatalog provider.
# Read-only access to nodes and services.

node_prefix "" {
  policy = "read"
}

service_prefix "" {
  policy = "read"
}
