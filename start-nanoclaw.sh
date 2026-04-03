#!/bin/bash
# start-nanoclaw.sh — Start NanoClaw in dev mode (no systemd required)
# Usage: ./start-nanoclaw.sh
# To stop: kill $(cat /tmp/nanoclaw.pid) 2>/dev/null

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="/tmp/nanoclaw.pid"
LOG_FILE="/tmp/nanoclaw-dev.log"
TSX="$PROJECT_DIR/node_modules/tsx/dist/cli.mjs"

cd "$PROJECT_DIR"

# ── Stop existing instance ────────────────────────────────────────────────────
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Stopping existing NanoClaw (PID $OLD_PID)..."
    kill "$OLD_PID" 2>/dev/null || true
    sleep 2
  fi
  rm -f "$PID_FILE"
fi

# Also kill any stale tsx/index.ts processes that weren't tracked
pkill -f "tsx.*index\.ts" 2>/dev/null || true
pkill -f "node.*tsx/dist/cli\.mjs" 2>/dev/null || true
sleep 1

# ── Check tsx binary ──────────────────────────────────────────────────────────
if [ ! -f "$TSX" ]; then
  echo "tsx not found at $TSX — running npm install..."
  npm install
fi

# ── Ensure better-sqlite3 native bindings are present ────────────────────────
SQLITE_CHECK="$PROJECT_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
if [ ! -f "$SQLITE_CHECK" ]; then
  echo "better-sqlite3 native bindings missing — downloading prebuilt binary..."
  SQLITE_DIR="$PROJECT_DIR/node_modules/better-sqlite3"
  # Try global prebuild-install first, then npx
  if command -v prebuild-install &>/dev/null; then
    (cd "$SQLITE_DIR" && prebuild-install) || true
  else
    (cd "$SQLITE_DIR" && npx --yes prebuild-install) || true
  fi
  if [ ! -f "$SQLITE_CHECK" ]; then
    echo "ERROR: Could not install better-sqlite3 bindings. Run 'npm install -g prebuild-install' then retry."
    exit 1
  fi
  echo "better-sqlite3 bindings installed."
fi

# ── Start NanoClaw ────────────────────────────────────────────────────────────
echo "Starting NanoClaw..."
node "$TSX" src/index.ts >> "$LOG_FILE" 2>&1 &
NANOCLAW_PID=$!
echo $NANOCLAW_PID > "$PID_FILE"
echo "NanoClaw started (PID $NANOCLAW_PID)"
echo "Log: tail -f $LOG_FILE"
