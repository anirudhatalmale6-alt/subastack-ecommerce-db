#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Build a throwaway database, apply everything, seed it, run the RLS
# test suite. This is what proves the security model before it goes
# anywhere near the real project.
#
#   ./scripts/local_test.sh                       # uses a temp cluster
#   DB_URL=postgres://... ./scripts/local_test.sh # uses your own server
# ---------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DB_NAME="${DB_NAME:-shop_test}"

if [ -n "${DB_URL:-}" ]; then
  URL="$DB_URL"
else
  export PATH="/usr/lib/postgresql/16/bin:$PATH"
  PGDIR="$(mktemp -d)/pg"
  PORT="${PGPORT:-$(python3 -c "import socket;s=socket.socket();s.bind(('',0));print(s.getsockname()[1]);s.close()")}"
  initdb -D "$PGDIR" -U dev --auth=trust >/dev/null
  pg_ctl -D "$PGDIR" -o "-p $PORT -k $PGDIR" -l "$PGDIR/server.log" start >/dev/null
  trap 'pg_ctl -D "$PGDIR" stop -m immediate >/dev/null 2>&1 || true' EXIT
  psql "postgresql://dev@localhost:$PORT/postgres?host=$PGDIR" -q -c "create database $DB_NAME"
  URL="postgresql://dev@localhost:$PORT/$DB_NAME?host=$PGDIR"
fi

"$HERE/scripts/apply.sh" "$URL" --with-shim
psql "$URL" -v ON_ERROR_STOP=1 -q -f "$HERE/sql/51_seed_auth_local.sql"

echo
echo "==> running tests/rls_tests.sql"
psql "$URL" -v ON_ERROR_STOP=1 -f "$HERE/tests/rls_tests.sql" 2>&1 | grep -E "PASS|FAIL|ERROR|ALL CHECKS"

echo
echo "==> re-applying everything a second time (idempotency check)"
"$HERE/scripts/apply.sh" "$URL" --with-shim >/dev/null
psql "$URL" -t -A -v ON_ERROR_STOP=1 -c \
  "select 'orders=' || count(*) from orders" -c \
  "select 'products=' || count(*) from products" -c \
  "select 'movements=' || count(*) from inventory_movements"
echo "==> ok"
