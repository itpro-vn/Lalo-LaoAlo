#!/bin/bash
# Generate self-signed TLS certificates for local development
set -euo pipefail

CERT_DIR="deployments/nginx/ssl"
mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
    echo "Certificates already exist in $CERT_DIR"
    echo "Delete them and re-run to regenerate."
    exit 0
fi

echo "Generating self-signed certificates for local development..."

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -subj "/CN=call.lalo.dev/O=Lalo Dev/C=VN" \
    -addext "subjectAltName=DNS:call.lalo.dev,DNS:localhost,IP:127.0.0.1"

echo "Certificates generated:"
echo "  $CERT_DIR/server.crt"
echo "  $CERT_DIR/server.key"
echo ""
echo "Add to /etc/hosts:  127.0.0.1 call.lalo.dev"
