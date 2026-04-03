#!/usr/bin/env bash
# init.sh — Initialize NanoClaw inside a Docker Sandbox.
# The repo is already mounted in the workspace (cloned on host).
#
# Usage (inside sandbox):
#   bash $(df -h | grep virtiofs | awk '{print $NF}')/nanoclaw/sandbox/init.sh

set -euo pipefail

NANOCLAW_DIR=$(df -h | grep virtiofs | head -1 | awk '{print $NF}')

echo ""
echo "=== NanoClaw Sandbox Init ==="
echo ""

if [ ! -f "${NANOCLAW_DIR}/package.json" ]; then
  echo "ERROR: NanoClaw not found at ${NANOCLAW_DIR}"
  echo "The repo should be cloned on the host before creating the sandbox."
  exit 1
fi

cd "$NANOCLAW_DIR"
echo "$NANOCLAW_DIR" > /home/agent/.nanoclaw-workspace

# ── 1. System dependencies ──────────────────────────────────────
echo "[1/5] Installing system dependencies..."
sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq build-essential >/dev/null 2>&1
npm config set strict-ssl false
if [ -n "${http_proxy:-}" ]; then
  npm config set proxy "$http_proxy"
  npm config set https-proxy "$http_proxy"
fi
if [ -f /usr/local/share/ca-certificates/proxy-ca.crt ]; then
  npm config set cafile /usr/local/share/ca-certificates/proxy-ca.crt
fi
echo "  done"

# ── 2. Install npm dependencies ─────────────────────────────────
echo "[2/5] Installing npm dependencies..."
rm -rf node_modules
npm install 2>&1 | tail -1
npm install https-proxy-agent 2>&1 | tail -1
echo "  done"

# ── 3. Apply sandbox patches ────────────────────────────────────
echo "[3/5] Applying sandbox patches..."
# Fix CRLF line endings (sed -i fails on virtiofs, use temp file + mv)
for f in sandbox/*.sh container/build.sh setup.sh; do
  if [ -f "$f" ]; then
    tr -d '\r' < "$f" > /tmp/_fixcrlf && mv /tmp/_fixcrlf "$f" && chmod +x "$f"
  fi
done
bash sandbox/sandbox-patch.sh 2>&1 | grep -E "\[ok\]|\[--\]|=== Done" || true
echo "  done"

# ── 4. Build NanoClaw + agent container ─────────────────────────
echo "[4/5] Building NanoClaw..."
npm run build 2>&1 | tail -1
bash container/build.sh 2>&1 | tail -3
echo "  done"

# ── 5. Commit sandbox patches so channel merges don't conflict ──
echo "[5/5] Committing sandbox patches..."
git add -A 2>/dev/null || true
git -c user.email="sandbox@nanoclaw.dev" -c user.name="NanoClaw Sandbox" \
  commit -m "chore: apply sandbox patches" --no-verify 2>/dev/null || true
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
