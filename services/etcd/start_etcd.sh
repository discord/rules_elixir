#!/usr/bin/env bash
# Start etcd for integration testing
#
# This script starts a single-node etcd cluster suitable for local testing.
# Data is stored in TEST_TMPDIR to work within Bazel's sandbox.

set -eo pipefail

# Use TEST_TMPDIR if available (Bazel test sandbox), otherwise fall back to temp dir
if [[ -n "$TEST_TMPDIR" ]]; then
    DATA_DIR="${ETCD_DATA_DIR:-$TEST_TMPDIR/etcd-data}"
else
    DATA_DIR="${ETCD_DATA_DIR:-$(mktemp -d)/etcd-data}"
fi
CLIENT_PORT="${ETCD_CLIENT_PORT:-2379}"
PEER_PORT="${ETCD_PEER_PORT:-2380}"

# Clean up any existing data for a fresh start
rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"

echo "[etcd] Starting etcd on port $CLIENT_PORT..."
echo "[etcd] Data directory: $DATA_DIR"

exec etcd \
    --name "itest-etcd" \
    --data-dir "$DATA_DIR" \
    --enable-v2 \
    --listen-client-urls "http://localhost:${CLIENT_PORT}" \
    --advertise-client-urls "http://localhost:${CLIENT_PORT}" \
    --listen-peer-urls "http://localhost:${PEER_PORT}" \
    --initial-advertise-peer-urls "http://localhost:${PEER_PORT}" \
    --initial-cluster "itest-etcd=http://localhost:${PEER_PORT}"
