#!/usr/bin/env bash
# nanoclaw-init.sh — Runs on first sandbox login.
# Clones NanoClaw, installs everything, applies patches, builds.

set -euo pipefail

WORKSPACE=$(df -h | grep virtiofs | head -1 | awk '{print $NF}')
NANOCLAW_DIR="${WORKSPACE}/nanoclaw"

echo ""
echo "=== NanoClaw first-time setup ==="
echo ""

if [ -z "$WORKSPACE" ]; then
  echo "ERROR: No workspace mount found"
  exit 1
fi

echo "$WORKSPACE" > /home/agent/.nanoclaw-workspace
npm config set strict-ssl false

# Clone NanoClaw (to home first — virtiofs can corrupt git packs)
echo "[1/6] Cloning NanoClaw..."
if [ -f "${NANOCLAW_DIR}/package.json" ]; then
  echo "  already exists"
else
  cd /home/agent
  git clone https://github.com/qwibitai/nanoclaw.git 2>&1 | tail -1
  mv /home/agent/nanoclaw "$NANOCLAW_DIR"
fi
echo "  done"

cd "$NANOCLAW_DIR"

# Install deps (clean node_modules first — virtiofs can leave stale state)
echo "[2/6] Installing dependencies..."
rm -rf node_modules
npm install 2>&1 | tail -1
npm install https-proxy-agent 2>&1 | tail -1
echo "  done"

# Apply sandbox patches
echo "[3/6] Applying sandbox patches..."
if [ -f /home/agent/sandbox-patch.sh ]; then
  bash /home/agent/sandbox-patch.sh 2>&1 | grep -E "\[ok\]|\[--\]|=== Done" || true
fi
echo "  done"

# Build NanoClaw
echo "[4/6] Building NanoClaw..."
npm run build 2>&1 | tail -1
echo "  done"

# Build agent container
echo "[5/6] Building agent container..."
bash container/build.sh 2>&1 | tail -3
echo "  done"

# Install Claude Code
echo "[6/6] Installing Claude Code..."
npm install -g @anthropic-ai/claude-code 2>&1 | tail -1
echo "  done"

touch /home/agent/.nanoclaw-initialized

echo ""
echo "========================================="
echo "  Setup complete!"
echo "========================================="
echo ""
echo "Run:"
echo "  cd ${NANOCLAW_DIR}"
echo "  claude"
echo "  /setup"
echo ""
