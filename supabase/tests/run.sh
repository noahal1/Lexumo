#!/usr/bin/env bash
# Run the sync SQL tests in a throwaway Postgres.
#
# Creates a fresh database, applies `tests/shim.sql` (the minimal slice of
# Supabase's schema a bare Postgres lacks), the migration, then the tests.
# Nothing touches an existing database; the container is disposable.
#
#   ./supabase/tests/run.sh              # start a container, test, remove it
#   ./supabase/tests/run.sh --keep       # leave the container up to poke at
#
# Needs Docker with a `postgres` image. On this machine that is
# `postgres:latest` (PostgreSQL 18.4).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
NAME="lexumo-sql-test-$$"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

cleanup() {
  if [ "$KEEP" = "0" ]; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  else
    echo "kept container: $NAME (docker exec -it $NAME psql -U postgres -d lexumo)"
  fi
}
trap cleanup EXIT

echo "== starting $NAME"
docker run -d --name "$NAME" \
  -e POSTGRES_PASSWORD=lexumo -e POSTGRES_DB=lexumo \
  postgres:latest >/dev/null

# `pg_isready` returns before the server accepts queries on first init, so poll
# a real connection instead of trusting the ready signal.
for i in $(seq 1 60); do
  if docker exec "$NAME" psql -U postgres -d lexumo -c 'select 1' >/dev/null 2>&1; then
    echo "== postgres up after ${i}s"
    break
  fi
  if [ "$i" = "60" ]; then
    echo "postgres did not start" >&2
    exit 1
  fi
  sleep 1
done

run_file() {
  echo "== $1"
  docker exec -i "$NAME" psql -U postgres -d lexumo -v ON_ERROR_STOP=1 -q -f - < "$1"
}

run_file "$HERE/shim.sql"
run_file "$ROOT/supabase/migrations/0001_sync.sql"

echo "== tests"
OUT="$(docker exec -i "$NAME" psql -U postgres -d lexumo -v ON_ERROR_STOP=1 -q -f - < "$HERE/sync.sql" 2>&1)" || {
  echo "$OUT" | sed 's/^psql:<stdin>:[0-9]*: NOTICE:  //'
  echo "FAILED" >&2
  exit 1
}
echo "$OUT" | sed 's/^psql:<stdin>:[0-9]*: NOTICE:  //' | grep -vE '^\s*$'
