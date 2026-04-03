#!/usr/bin/env bash
# start.sh — Enter sandbox and start NanoClaw
# Usage: bash sandbox/start.sh [--dev]
set -euo pipefail

NANOCLAW_DIR=$(df -h | grep virtiofs | head -1 | awk '{print $NF}')
cd "$NANOCLAW_DIR"

# Run init if not yet done (idempotent)
if [ ! -f "$HOME/.nanoclaw-initialized" ] || [ ! -f dist/index.js ]; then
  bash sandbox/init.sh
fi

# Stop existing instance if running
if [ -f nanoclaw.pid ]; then
  OLD_PID=$(cat nanoclaw.pid 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Stopping existing NanoClaw (PID $OLD_PID)..."
    kill "$OLD_PID" 2>/dev/null || true
    sleep 2
  fi
fi

mkdir -p logs

if [ "${1:-}" = "--dev" ]; then
  npm run dev
else
  nohup node dist/index.js \
    >> logs/nanoclaw.log \
    2>> logs/nanoclaw.error.log &
  echo $! > nanoclaw.pid
  echo "NanoClaw started (PID $!)"
  echo "Logs: tail -f $NANOCLAW_DIR/logs/nanoclaw.log"
fi
