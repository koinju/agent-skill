#!/usr/bin/env bash
# Dump the live Koinju ClickHouse schema (database = api) over HTTPS.
# Read-only: only DESCRIBE TABLE and SELECT FROM system.tables.
#
# Use this to verify the bundled references (data-tables.md etc.) against
# reality, or to discover columns before writing a query. Run it whenever
# a query fails with "Unknown table" or "Unknown column".
#
# Usage:
#   bash probe-schema.sh                # dump all api.* tables and columns
#   bash probe-schema.sh <table>        # dump columns for one table only

set -u

# Auto-source .koinju.env (project) then ~/.koinju.env (global) — same as helpers
# shellcheck disable=SC1091
[ -f .koinju.env ] && source .koinju.env 2>/dev/null || true
# shellcheck disable=SC1091
[ -f "$HOME/.koinju.env" ] && source "$HOME/.koinju.env" 2>/dev/null || true

for v in KOINJU_DB_HOST KOINJU_DB_USER KOINJU_DB_PASSWORD; do
    if [ -z "${!v:-}" ]; then
        echo "[probe-schema] missing $v — set in .koinju.env or ~/.koinju.env" >&2
        exit 1
    fi
done

# Normalize host (strip scheme / path / port if user pasted a full URL)
HOST="$KOINJU_DB_HOST"
HOST="${HOST#https://}"
HOST="${HOST#http://}"
HOST="${HOST%%/*}"
case "$HOST" in
    *:*[0-9]) HOST="${HOST%:*}" ;;
esac
PORT="${KOINJU_DB_PORT:-8443}"
DB="${KOINJU_DB_DATABASE:-api}"

# Base64 for HTTP basic auth (BSD and GNU compatible)
AUTH=$(printf '%s' "$KOINJU_DB_USER:$KOINJU_DB_PASSWORD" | base64 | tr -d '\n')
URL="https://$HOST:$PORT/"

run_q() {
    local sql="$1"
    curl -sS -H "Authorization: Basic $AUTH" -H "X-ClickHouse-Database: $DB" \
        --data-binary "$sql" "$URL"
}

if [ $# -ge 1 ]; then
    # One-table mode
    TBL="$1"
    echo "=== columns of $DB.$TBL ==="
    run_q "DESCRIBE TABLE $DB.$TBL FORMAT TSV" | awk -F'\t' '{printf "  %-32s %s\n", $1, $2}'
    exit 0
fi

echo "=== tables in $DB ==="
TABLES=$(run_q "SELECT name FROM system.tables WHERE database = '$DB' ORDER BY name FORMAT TSV")
echo "$TABLES" | sed 's/^/  /'
echo

for t in $TABLES; do
    echo "--- $DB.$t ---"
    run_q "DESCRIBE TABLE $DB.$t FORMAT TSV" | awk -F'\t' '{printf "  %-32s %s\n", $1, $2}'
    echo
done
