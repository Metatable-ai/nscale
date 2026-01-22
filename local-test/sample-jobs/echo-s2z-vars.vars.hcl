// Copyright 2026 Metatable Inc.
// SPDX-License-Identifier: Apache-2.0

service_name = "echo-s2z-vars"
host         = "echo-s2z-vars.localhost"
image        = "hashicorp/http-echo"
response_text = "Hello from scale-to-zero service (vars)!"
idle_timeout = "20"
job_spec_kv  = "scale-to-zero/jobs/echo-s2z-vars"
