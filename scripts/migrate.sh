#!/usr/bin/env bash
# Run Postgres migrations up/down
# Usage: ./scripts/migrate.sh [up|down|version|force N]

set -euo pipefail

MIGRATIONS_DIR="migrations/postgres"
DB_URL="${DATABASE_URL:-postgres://lalo:lalo_dev@localhost:5432/lalo?sslmode=disable}"
ACTION="${1:-up}"

if ! command -v migrate &> /dev/null; then
    echo "Error: golang-migrate CLI not found."
    echo "Install: brew install golang-migrate"
    exit 1
fi

shift 2>/dev/null || true
migrate -path "$MIGRATIONS_DIR" -database "$DB_URL" "$ACTION" "$@"
