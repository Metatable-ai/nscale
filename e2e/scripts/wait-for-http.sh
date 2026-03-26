#!/bin/sh
# Copyright 2026 Metatable Inc.
# SPDX-License-Identifier: Apache-2.0

set -eu

url="$1"
name="${2:-endpoint}"
timeout_seconds="${WAIT_TIMEOUT_SECONDS:-120}"

start="$(date +%s)"
while true; do
  if curl -fsS "$url" >/dev/null 2>&1; then
    echo "$name ready: $url"
    exit 0
  fi

  now="$(date +%s)"
  if [ $((now - start)) -ge "$timeout_seconds" ]; then
    echo "$name not ready after ${timeout_seconds}s: $url" >&2
    exit 1
  fi

  sleep 2
done