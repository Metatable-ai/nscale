# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Nomad ACL policy for nscale (scale-to-zero operations).

namespace "*" {
  policy = "write"
  capabilities = ["submit-job", "read-job", "scale-job"]
}
