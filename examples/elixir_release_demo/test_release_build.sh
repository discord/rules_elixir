#!/bin/bash

# Test that the Elixir release was built correctly

set -euo pipefail

# Source runfiles library
# --- begin runfiles.bash initialization v2 ---
# Copy-pasted from the Bazel Bash runfiles library v2.
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v2 ---

echo "Testing Elixir release build..."

# Check that release files exist
RELEASE_FILES=(
    "elixir_release_demo.rel"
    "elixir_release_demo.script"
    "elixir_release_demo.boot"
    "elixir_release_demo.manifest"
)

for file in "${RELEASE_FILES[@]}"; do
    if ! find . -name "$file" -type f | grep -q .; then
        echo "ERROR: Expected release file not found: $file"
        exit 1
    fi
done

echo "✓ All release files present"

# Check that bundle directory exists
if ! find . -name "*_bundle" -type d | grep -q .; then
    echo "ERROR: Bundle directory not found"
    exit 1
fi

echo "✓ Bundle directory created"

# Check bundle structure
BUNDLE_DIR=$(find . -name "*_bundle" -type d | head -1)

if [ ! -d "$BUNDLE_DIR/bin" ]; then
    echo "ERROR: Bundle missing bin directory"
    exit 1
fi

if [ ! -d "$BUNDLE_DIR/lib" ]; then
    echo "ERROR: Bundle missing lib directory"
    exit 1
fi

if [ ! -d "$BUNDLE_DIR/releases" ]; then
    echo "ERROR: Bundle missing releases directory"
    exit 1
fi

echo "✓ Bundle structure is correct"

# Check for startup script
if [ ! -f "$BUNDLE_DIR/bin/elixir_release_demo" ]; then
    echo "ERROR: Startup script not found"
    exit 1
fi

if [ ! -x "$BUNDLE_DIR/bin/elixir_release_demo" ]; then
    echo "ERROR: Startup script not executable"
    exit 1
fi

echo "✓ Startup script present and executable"

echo ""
echo "All tests passed! Elixir release built successfully."