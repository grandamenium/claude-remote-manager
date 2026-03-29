#!/bin/bash
# Clearpath DB disk usage monitor
# Runs on cron, alerts via Telegram if usage > WARN_PERCENT
# Also alerts if DB is completely unreachable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(dirname "$SCRIPT_DIR")"
BUS_DIR="$(dirname "$(dirname "$AGENT_DIR")")/core/bus"
TELEGRAM="$BUS_DIR/send-telegram.sh"
CHAT_ID="6690120787"

# Load DB URL from env file or Railway vars
DB_URL="${CLEARPATH_DB_URL:-postgresql://postgres:ggqLoIoFnOHInCFqcrWYkddSJLDrRwkB@switchyard.proxy.rlwy.net:23730/railway}"

WARN_PERCENT=75
CRIT_PERCENT=90

send_alert() {
  bash "$TELEGRAM" "$CHAT_ID" "$1"
}

# Try connecting - if unreachable, alert immediately
if ! PGPASSWORD=$(echo "$DB_URL" | sed 's|.*://[^:]*:\([^@]*\)@.*|\1|') \
   psql "$DB_URL" -c "SELECT 1" --no-psqlrc -q 2>/dev/null | grep -q "1"; then
  send_alert "Clearpath DB health check: DB is unreachable. Check Railway Postgres service."
  exit 1
fi

# Query DB size and top tables
QUERY="
SELECT
  pg_database_size(current_database()) as db_bytes,
  pg_size_pretty(pg_database_size(current_database())) as db_size,
  (SELECT setting::bigint * 1024 FROM pg_settings WHERE name = 'block_size') *
  (SELECT setting::bigint FROM pg_settings WHERE name = 'data_checksums') as placeholder
FROM pg_database WHERE datname = current_database();
"

TOP_TABLES_QUERY="
SELECT
  relname as table_name,
  pg_size_pretty(pg_total_relation_size(oid)) as size,
  pg_total_relation_size(oid) as size_bytes
FROM pg_class
WHERE relkind = 'r' AND relnamespace = 'public'::regnamespace
ORDER BY pg_total_relation_size(oid) DESC
LIMIT 5;
"

DB_SIZE=$(PGPASSWORD=$(echo "$DB_URL" | sed 's|.*://[^:]*:\([^@]*\)@.*|\1|') \
  psql "$DB_URL" --no-psqlrc -t -A -c \
  "SELECT pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null | tr -d ' ')

DB_BYTES=$(PGPASSWORD=$(echo "$DB_URL" | sed 's|.*://[^:]*:\([^@]*\)@.*|\1|') \
  psql "$DB_URL" --no-psqlrc -t -A -c \
  "SELECT pg_database_size(current_database());" 2>/dev/null | tr -d ' ')

# Railway free tier Postgres default volume is 1GB = 1073741824 bytes
# Try to get actual volume size from pg_settings if available
# Fallback to 1GB
VOLUME_BYTES=1073741824

if [ -n "$DB_BYTES" ] && [ "$DB_BYTES" -gt 0 ] 2>/dev/null; then
  PERCENT=$(( DB_BYTES * 100 / VOLUME_BYTES ))

  TOP_TABLES=$(PGPASSWORD=$(echo "$DB_URL" | sed 's|.*://[^:]*:\([^@]*\)@.*|\1|') \
    psql "$DB_URL" --no-psqlrc -t -A -F' | ' -c \
    "SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) FROM pg_class WHERE relkind='r' AND relnamespace='public'::regnamespace ORDER BY pg_total_relation_size(oid) DESC LIMIT 5;" 2>/dev/null)

  if [ "$PERCENT" -ge "$CRIT_PERCENT" ]; then
    send_alert "CRITICAL: Clearpath DB is at ${PERCENT}% disk (${DB_SIZE} of ~1GB). Top tables: ${TOP_TABLES}. Resize Railway Postgres volume NOW or DB will crash."
  elif [ "$PERCENT" -ge "$WARN_PERCENT" ]; then
    send_alert "WARNING: Clearpath DB is at ${PERCENT}% disk (${DB_SIZE} of ~1GB). Top tables: ${TOP_TABLES}. Consider cleanup or volume resize soon."
  else
    echo "$(date): DB disk OK - ${DB_SIZE} (~${PERCENT}% of 1GB)"
  fi
fi
