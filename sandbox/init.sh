#!/usr/bin/env bash
# init.sh — Initialize NanoClaw inside a Docker Sandbox.
# The repo is already mounted in the workspace (cloned on host).
#
# Usage (inside sandbox):
#   bash $(df -h | grep virtiofs | awk '{print $NF}')/nanoclaw/sandbox/init.sh

set -euo pipefail

WORKSPACE=$(df -h | grep virtiofs | head -1 | awk '{print $NF}')
NANOCLAW_DIR="${WORKSPACE}/nanoclaw"

echo ""
echo "=== NanoClaw Sandbox Init ==="
echo ""

if [ ! -f "${NANOCLAW_DIR}/package.json" ]; then
  echo "ERROR: NanoClaw not found at ${NANOCLAW_DIR}"
  echo "The repo should be cloned on the host before creating the sandbox."
  exit 1
fi

cd "$NANOCLAW_DIR"
echo "$WORKSPACE" > /home/agent/.nanoclaw-workspace
npm config set strict-ssl false

# ── 1. Install npm dependencies ─────────────────────────────────
echo "[1/4] Installing npm dependencies..."
rm -rf node_modules
npm install 2>&1 | tail -1
npm install https-proxy-agent 2>&1 | tail -1
echo "  done"

# ── 2. Apply sandbox patches ────────────────────────────────────
echo "[2/4] Applying sandbox patches..."
sed -i 's/\r$//' sandbox/sandbox-patch.sh 2>/dev/null || true
bash sandbox/sandbox-patch.sh 2>&1 | grep -E "\[ok\]|\[--\]|=== Done" || true
echo "  done"

# ── 3. Build NanoClaw + agent container ─────────────────────────
echo "[3/4] Building NanoClaw..."
npm run build 2>&1 | tail -1
bash container/build.sh 2>&1 | tail -3
echo "  done"

# ── 4. Install Claude Code ──────────────────────────────────────
echo "[4/4] Installing Claude Code..."
npm install -g @anthropic-ai/claude-code 2>&1 | tail -1
echo "  done"

touch /home/agent/.nanoclaw-initialized

echo ""
echo "========================================="
echo "  NanoClaw is ready!"
echo "========================================="
echo ""
echo "Run:"
echo "  cd ${NANOCLAW_DIR}"
echo "  claude"
echo "  /setup"
echo ""
