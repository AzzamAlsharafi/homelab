#!/bin/bash
set -e

# Configuration
mkdir -p "$DUMP_DIR"

echo "Starting Pre-Snapshot Database Dumps..."

# --- Zitadel (Postgres) ---
# We use the container name defined in your docker-compose
docker exec zitadel_db pg_dump --clean --if-exists -U "$PGUSER" zitadel | gzip > "$DUMP_DIR/zitadel_db.sql.gz"
docker exec immich_postgres pg_dumpall --clean --if-exists -U "$POSTGRES_USER" | gzip > "$DUMP_DIR/immich_db.sql.gz"

# --- SQLite (If Authelia/other use a file) ---
# If a service uses SQLite, it's safer to use the sqlite3 backup command
# docker exec authelia sqlite3 /config/db.sqlite3 ".backup '/storage/backups/db_dumps/authelia_sqlite_$(date +%F).db'"

echo "All database dumps completed successfully."