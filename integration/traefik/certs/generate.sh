#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_FILE="$SCRIPT_DIR/server.crt"
KEY_FILE="$SCRIPT_DIR/server.key"

if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required to generate Traefik TLS certificates" >&2
  exit 1
fi

OPENSSL_CONFIG="$(mktemp)"
trap 'rm -f "$OPENSSL_CONFIG"' EXIT

cat > "$OPENSSL_CONFIG" <<'EOF'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = localhost

[v3_req]
subjectAltName = @alt_names
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = localhost
DNS.2 = *.localhost
EOF

openssl req \
  -x509 \
  -nodes \
  -newkey rsa:2048 \
  -sha256 \
  -days 3650 \
  -keyout "$KEY_FILE" \
  -out "$CERT_FILE" \
  -config "$OPENSSL_CONFIG" >/dev/null 2>&1
