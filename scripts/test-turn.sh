#!/usr/bin/env bash
# Test TURN server connectivity and allocation
# Usage: ./scripts/test-turn.sh [TURN_HOST] [TURN_PORT] [SECRET]
set -euo pipefail

TURN_HOST="${1:-localhost}"
TURN_PORT="${2:-3478}"
TURN_SECRET="${3:-lalo-turn-dev-secret}"
USER_ID="test-user-$(date +%s)"

echo "=== TURN Server Test ==="
echo "Host: ${TURN_HOST}:${TURN_PORT}"
echo ""

# 1. STUN binding test
echo "[1/3] STUN binding test..."
if command -v turnutils_stunclient &>/dev/null; then
    turnutils_stunclient "${TURN_HOST}" -p "${TURN_PORT}" && echo "  PASS: STUN binding OK" || echo "  FAIL: STUN binding failed"
else
    echo "  SKIP: turnutils_stunclient not found (install coturn-utils)"
fi
echo ""

# 2. Generate HMAC credentials
echo "[2/3] Generating HMAC credentials..."
EXPIRY=$(($(date +%s) + 86400))
USERNAME="${EXPIRY}:${USER_ID}"
PASSWORD=$(echo -n "${USERNAME}" | openssl dgst -sha1 -hmac "${TURN_SECRET}" -binary | openssl base64)
echo "  Username: ${USERNAME}"
echo "  Password: ${PASSWORD}"
echo ""

# 3. TURN allocation test
echo "[3/3] TURN allocation test..."
if command -v turnutils_uclient &>/dev/null; then
    turnutils_uclient -t -u "${USERNAME}" -w "${PASSWORD}" "${TURN_HOST}" -p "${TURN_PORT}" -n 1 -c && \
        echo "  PASS: TURN allocation OK" || \
        echo "  FAIL: TURN allocation failed"
else
    echo "  SKIP: turnutils_uclient not found (install coturn-utils)"
    echo "  Alternative: use Go test client"
    echo "    go run ./cmd/turn-test/ -host ${TURN_HOST} -port ${TURN_PORT} -secret ${TURN_SECRET}"
fi
echo ""
echo "=== Done ==="
