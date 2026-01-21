#!/bin/bash

# Configuration
echo "Starting Post-Snapshot Cleanup..."

# Remove the dump directory
# We only delete the LOCAL copies; they are safe in Backblaze via Kopia
rm -rf "$DUMP_DIR"

echo "Cleanup completed."