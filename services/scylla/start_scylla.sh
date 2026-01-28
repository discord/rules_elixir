#!/usr/bin/env bash
# Start Scylla (Cassandra-compatible) database for integration testing
#
# This script uses Docker Compose to start a single Scylla node.
# Data is stored in $HOME/var/scylla-itest to avoid conflicts.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCYLLA_DATA_DIR:-$HOME/var/scylla-itest}"

# Create data directory
mkdir -p "$DATA_DIR"

# Stop any existing container
echo "[scylla] Stopping any existing scylla-itest container..."
docker rm -f scylla-itest 2>/dev/null || true

# Start scylla using docker-compose
echo "[scylla] Starting Scylla on port 9042..."
echo "[scylla] Data directory: $DATA_DIR"

cd "$SCRIPT_DIR"
exec docker-compose up --remove-orphans
