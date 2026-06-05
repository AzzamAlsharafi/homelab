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

# --- OpenCloud extended attributes ---
# Kopia does NOT back up xattrs, but OpenCloud's posix storage driver keeps ALL
# of its file metadata (id, parentid, name, checksums, tree sizes, ...) in
# user.oc.* xattrs. We dump them to a sidecar that the snapshot DOES capture, and
# replay it on restore (see deploy.sh). The Kopia image has no getfattr, so a
# throwaway alpine helper reads them and writes to stdout, which we capture into
# $DUMP_DIR exactly like the DB dumps above. The helper runs on the HOST docker
# daemon, so the read-only input mount (/storage/opencloud) is a HOST path.
echo "Dumping OpenCloud xattrs..."
docker run --rm \
  -v /storage/opencloud:/storage/opencloud:ro \
  alpine:latest sh -c \
  'apk add --no-cache attr >/dev/null 2>&1 && getfattr -R -d -h -P --absolute-names -m "^user\.oc" /storage/opencloud' \
  > "$DUMP_DIR/opencloud.xattr" || true

# Verify the sidecar is sane (this check runs inside the Kopia container -> $DUMP_DIR).
# We warn but DO NOT fail the backup: file contents are still snapshotted regardless.
if grep -q "user.oc" "$DUMP_DIR/opencloud.xattr" 2>/dev/null; then
    echo "OpenCloud xattr dump OK ($(grep -c '^# file:' "$DUMP_DIR/opencloud.xattr") objects)."
else
    echo "WARNING: OpenCloud xattr dump is empty/failed - this snapshot will not be able to restore opencloud xattrs!" >&2
fi

echo "All database dumps completed successfully."