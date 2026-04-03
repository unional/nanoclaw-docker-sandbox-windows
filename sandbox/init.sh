#!/usr/bin/env bash
# init.sh — Sandbox-specific prep for NanoClaw inside a Docker Sandbox.
# Handles proxy config, CRLF fixes, and the virtiofs symlink workaround.
# The /setup skill handles build, container, channels, and everything else.

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

# ── 1. Proxy + npm config ────────────────────────────────────────
echo "[1/3] Configuring proxy..."
if [ -n "${http_proxy:-}" ]; then
  npm config set strict-ssl false 2>/dev/null
  npm config set proxy "$http_proxy"
  npm config set https-proxy "$http_proxy"
fi
if [ -f /usr/local/share/ca-certificates/proxy-ca.crt ]; then
  npm config set cafile /usr/local/share/ca-certificates/proxy-ca.crt
fi
echo "  done"

# ── 2. Fix CRLF + install deps (virtiofs workaround) ─────────────
echo "[2/3] Installing dependencies..."

# Fix CRLF from Windows host (same-filesystem temp to avoid cross-device mv)
find "$NANOCLAW_DIR" -maxdepth 2 -name "*.sh" -exec sh -c \
  'tr -d "\r" < "$1" > "$1.tmp" && mv "$1.tmp" "$1" && chmod +x "$1"' _ {} \;

# virtiofs doesn't support symlinks — install in /tmp (ext4), tar-pipe back
mkdir -p /tmp/npm-build
cp package.json package-lock.json /tmp/npm-build/
(cd /tmp/npm-build && npm install >> /tmp/npm-build.log 2>&1)
(cd /tmp/npm-build && npm install https-proxy-agent undici >> /tmp/npm-build.log 2>&1) || true

# Tar-pipe node_modules back (tolerate symlink errors)
rm -rf node_modules
(cd /tmp/npm-build && tar cf - node_modules) | tar xf - 2>/dev/null || true

# Create shell wrapper scripts for .bin/ (symlinks don't work on virtiofs)
rm -rf node_modules/.bin
mkdir -p node_modules/.bin
if [ -d /tmp/npm-build/node_modules/.bin ]; then
  (cd /tmp/npm-build/node_modules/.bin && for f in *; do
    if [ -L "$f" ]; then
      target=$(readlink "$f")
      cat > "${NANOCLAW_DIR}/node_modules/.bin/$f" << WRAPPER
#!/bin/sh
exec "${NANOCLAW_DIR}/node_modules/.bin/${target}" "\$@"
WRAPPER
      chmod +x "${NANOCLAW_DIR}/node_modules/.bin/$f"
    fi
  done)
fi

# Copy actual binaries for packages that check platform at runtime (not just .bin wrappers)
# esbuild's JS code looks for @esbuild/linux-x64 — ensure it survived the tar-pipe
if [ -f /tmp/npm-build/node_modules/esbuild/bin/esbuild ] && [ -d node_modules/esbuild/bin ]; then
  cp /tmp/npm-build/node_modules/esbuild/bin/esbuild node_modules/.bin/esbuild 2>/dev/null || true
fi

# Verify
node -e "require('better-sqlite3')" 2>/dev/null && echo "  better-sqlite3: OK" || echo "  better-sqlite3: FAILED"
node_modules/.bin/tsc --version 2>/dev/null && echo "  tsc: OK" || echo "  tsc: FAILED"
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
