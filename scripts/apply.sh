#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Apply the whole schema to a database.
#
#   ./scripts/apply.sh "postgresql://postgres:PASS@db.<ref>.subastack.co:5432/postgres"
#
# Add --with-shim when running against a plain Postgres that has no auth
# schema (local dev, CI). Add --no-seed to skip the demo data.
# ---------------------------------------------------------------------
set -euo pipefail

DB_URL="${1:-${DATABASE_URL:-}}"
if [ -z "$DB_URL" ]; then
  echo "usage: $0 <postgres-connection-url> [--with-shim] [--no-seed]" >&2
  exit 2
fi
shift || true

WITH_SHIM=0
WITH_SEED=1
for arg in "$@"; do
  case "$arg" in
    --with-shim) WITH_SHIM=1 ;;
    --no-seed)   WITH_SEED=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")/.." && pwd)"

FILES=(sql/00_extensions_roles.sql)
[ "$WITH_SHIM" -eq 1 ] && FILES+=(sql/01_auth_shim.sql)
FILES+=(
  sql/10_schema.sql
  sql/15_views.sql
  sql/20_functions_triggers.sql
  sql/25_rpc_guards.sql
  sql/26_auth_hook.sql
  sql/30_rls_policies.sql
  sql/40_grants.sql
)
[ "$WITH_SEED" -eq 1 ] && FILES+=(sql/50_seed.sql)

for f in "${FILES[@]}"; do
  echo "==> $f"
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f "$HERE/$f"
done

echo "==> done"
