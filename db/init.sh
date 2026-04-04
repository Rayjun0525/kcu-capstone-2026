#!/usr/bin/env bash
# db/init.sh
# Initializes the PostgreSQL instance inside the Docker container.
# Executed automatically by the official postgres image via /docker-entrypoint-initdb.d/

set -euo pipefail

PSQL="psql -v ON_ERROR_STOP=1 --username=${POSTGRES_USER} --dbname=${POSTGRES_DB}"

echo "==> [init] Creating ALMA schema..."
for f in /docker-entrypoint-initdb.d/alma/*.sql; do
    echo "    loading $f"
    $PSQL -f "$f"
done

echo "==> [init] Creating e-commerce schema..."
for f in /docker-entrypoint-initdb.d/ecommerce/*.sql; do
    echo "    loading $f"
    $PSQL -f "$f"
done

echo "==> [init] Done."
