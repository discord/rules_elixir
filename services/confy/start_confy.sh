#!/usr/bin/env bash
# Start confy (configuration service) for integration testing
#
# Confy is Discord's configuration service that stores configs in etcd.
# This script assumes the confy tool is available in the path or via
# the CONFY_PATH environment variable.
#
# NOTE: This is a placeholder. The actual confy implementation is in
# the discord repository. For integration tests, you may want to:
# 1. Use a mock confy server
# 2. Directly populate etcd with test configs
# 3. Use the actual confy from discord_devops/config

set -eo pipefail

CONFY_PORT="${CONFY_PORT:-8500}"
ETCD_URL="${ETCD_URL:-http://localhost:2379}"

echo "[confy] Starting confy on port $CONFY_PORT..."
echo "[confy] Using etcd at $ETCD_URL"

# Check if confy is available
if command -v confy &> /dev/null; then
    exec confy serve --port "$CONFY_PORT" --etcd-url "$ETCD_URL"
elif [[ -n "$CONFY_PATH" && -x "$CONFY_PATH" ]]; then
    exec "$CONFY_PATH" serve --port "$CONFY_PORT" --etcd-url "$ETCD_URL"
else
    echo "[confy] WARNING: confy not found. Running mock server..."
    echo "[confy] To use real confy, set CONFY_PATH or ensure 'confy' is in PATH"

    # Simple mock that just responds with empty config
    # This allows tests to proceed without a real confy server
    python3 -c "
import http.server
import json

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        if self.path == '/health':
            self.wfile.write(b'{\"status\": \"ok\"}')
        else:
            self.wfile.write(b'{}')
    def log_message(self, format, *args):
        print(f'[confy-mock] {format % args}')

server = http.server.HTTPServer(('localhost', $CONFY_PORT), Handler)
print(f'[confy-mock] Mock server listening on port $CONFY_PORT')
server.serve_forever()
"
fi
