#!/usr/bin/env bash
#
# Quick dev cycle: kill → build → bundle → relaunch
# Usage: ./Scripts/dev.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Kill running instance
pkill -x Battery 2>/dev/null && sleep 0.3 || true

# Build
echo "Building..."
cd "$PROJECT_DIR"
swift build 2>&1 | tail -1

# Bundle
bash "$SCRIPT_DIR/bundle.sh" debug

# Verify the bundle actually contains the binary we just built —
# codesigning rewrites bytes, but the Mach-O UUID survives it.
BUILT_UUID=$(dwarfdump --uuid "$PROJECT_DIR/.build/debug/Battery" | awk '{print $2}')
BUNDLED_UUID=$(dwarfdump --uuid "$PROJECT_DIR/Battery.app/Contents/MacOS/Battery" | awk '{print $2}')
if [[ "$BUILT_UUID" != "$BUNDLED_UUID" ]]; then
    echo "ERROR: Bundled binary is stale (UUID mismatch)" >&2
    echo "  built:   $BUILT_UUID" >&2
    echo "  bundled: $BUNDLED_UUID" >&2
    exit 1
fi

# Launch
echo "Launching..."
open "$PROJECT_DIR/Battery.app"
