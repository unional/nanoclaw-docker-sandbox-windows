#!/usr/bin/env bash
# init.sh — Initialize NanoClaw inside a Docker Sandbox.
# The repo is already mounted in the workspace (cloned on host).

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
echo "[1/3] Installing system dependencies..."
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
echo "[2/3] Installing npm dependencies..."
# Fix CRLF line endings from Windows host clone
for f in container/build.sh setup.sh; do
  if [ -f "$f" ]; then
    tr -d '\r' < "$f" > /tmp/_fixcrlf && mv /tmp/_fixcrlf "$f" && chmod +x "$f"
  fi
done
npm install 2>&1 | tail -1
echo "  done"

# ── 3. Build NanoClaw + agent container ─────────────────────────
echo "[3/3] Building NanoClaw..."
npm run build 2>&1 | tail -1
bash container/build.sh 2>&1 | tail -3
echo "  done"

touch /home/agent/.nanoclaw-initialized

echo ""
echo "========================================="
echo "  NanoClaw is ready!"
echo "========================================="
echo ""
echo "Type /setup to continue configuration."
echo ""
