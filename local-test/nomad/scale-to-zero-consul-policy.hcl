// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0

node_prefix "" {
  policy = "read"
}

key_prefix "scale-to-zero/" {
  policy = "write"
}

# Read for service discovery, write for potential cleanup of orphaned services
service_prefix "" {
  policy = "write"
}