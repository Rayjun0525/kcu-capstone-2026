#!/bin/bash
# init.sh — Bootstrap ALMA extension in Docker PostgreSQL
# Executed once by docker-entrypoint on first container start
set -e

PSQL="psql -v ON_ERROR_STOP=1 --username=${POSTGRES_USER} --dbname=${POSTGRES_DB}"

echo "==> Installing prerequisites..."
$PSQL -c "CREATE EXTENSION IF NOT EXISTS vector;"
$PSQL -c "CREATE EXTENSION IF NOT EXISTS plpython3u;"

echo "==> Loading ALMA SQL files..."
for f in /docker-entrypoint-initdb.d/sql/0[1-9]_*.sql \
          /docker-entrypoint-initdb.d/sql/1[0-2]_*.sql; do
    echo "    -> $f"
    $PSQL -f "$f"
done

echo "==> ALMA bootstrap complete."
