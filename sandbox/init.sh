#!/usr/bin/env bash
# init.sh — Sandbox-specific prep for NanoClaw inside a Docker Sandbox.
# Only does what /setup can't: proxy config, CRLF fixes, proxy packages.
# The /setup skill handles build, container, and everything else.

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

# ── 1. Sandbox-specific system prep ──────────────────────────────
echo "[1/3] Configuring sandbox environment..."
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

# ── 2. Fix CRLF + install deps (with proxy packages) ─────────────
echo "[2/3] Installing dependencies..."
# Fix CRLF line endings from Windows host clone
for f in container/build.sh setup.sh; do
  if [ -f "$f" ]; then
    tr -d '\r' < "$f" > /tmp/_fixcrlf && mv /tmp/_fixcrlf "$f" && chmod +x "$f"
  fi
done
npm install 2>&1 | tail -1
npm install https-proxy-agent undici 2>&1 | tail -1
echo "  done"

# ── 3. Commit sandbox deps so channel merges have clean tree ─────
echo "[3/3] Committing sandbox dependencies..."
git add package.json package-lock.json 2>/dev/null
git diff --cached --quiet || git commit -m "chore: add sandbox proxy dependencies" --no-verify 2>&1 | tail -1
echo "  done"

touch /home/agent/.nanoclaw-initialized

echo ""
echo "========================================="
echo "  Sandbox prep complete!"
echo "========================================="
echo ""
echo "Type /setup to continue (builds, container, channels)."
echo ""
