#!/usr/bin/env bash
# Applies migrations/ to PostgreSQL with the migrator the image ships
# (`migrate` on PATH), the way deployments run it:
#   1. a fresh install: every migration into an empty database;
#   2. an upgrade: BASE's migrations first, then this change's on top;
#   3. the migrations this change adds, rolled back one at a time and applied
#      again. Older migrations are not rolled back: several have no @DOWN on
#      purpose.
# Connection settings come from DB_HOST, DB_PORT, DB_USER, DB_PASSWORD and
# DB_SSLMODE; the script creates and drops its own databases.
#
# Usage: test-migrations.sh BASE
set -euo pipefail

base="${1:?usage: test-migrations.sh BASE}"
: "${DB_HOST:?}" "${DB_PORT:?}" "${DB_USER:?}" "${DB_PASSWORD:?}"
export DB_DRIVER=postgres

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git archive "$base" migrations | tar -x -C "$tmp"

# File names in a directory, in sorted order.
names() { local f; for f in "$1"/*; do [ -e "$f" ] && printf '%s\n' "${f##*/}"; done; }
admin() { PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -qc "$1"; }
new_database() { admin "DROP DATABASE IF EXISTS $1"; admin "CREATE DATABASE $1"; }
migrate_in() { DB_NAME="$1" MIGRATION_DIR="$2" migrate "$3"; }
pending() { migrate_in "$1" "$2" status | awk '$3 == "pending"' | wc -l | tr -d ' '; }
expect_pending() {
  local count
  count=$(pending "$1" migrations)
  if [ "$count" -ne "$2" ]; then
    echo "Expected $2 pending migration(s) in $1, found ${count}." >&2
    migrate_in "$1" migrations status >&2
    exit 1
  fi
}

echo "== Fresh install"
new_database migrations_fresh
migrate_in migrations_fresh migrations up
expect_pending migrations_fresh 0

echo "== Upgrade from ${base}"
new_database migrations_upgrade
migrate_in migrations_upgrade "$tmp/migrations" up
migrate_in migrations_upgrade migrations up
expect_pending migrations_upgrade 0

added=$(comm -13 <(names "$tmp/migrations") <(names migrations) | wc -l | tr -d ' ')
if [ "$added" -eq 0 ]; then
  echo "== No new migrations to roll back"
  exit 0
fi

echo "== Roll back and re-apply the ${added} new migration(s)"
for _ in $(seq "$added"); do
  migrate_in migrations_upgrade migrations down
done
expect_pending migrations_upgrade "$added"
migrate_in migrations_upgrade migrations up
expect_pending migrations_upgrade 0
