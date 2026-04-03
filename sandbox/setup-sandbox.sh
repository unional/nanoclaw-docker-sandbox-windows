#!/usr/bin/env bash
# setup-sandbox.sh — Set up NanoClaw in a Docker AI Sandbox.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/qwibitai/nanoclaw/main/sandbox/setup-sandbox.sh | bash
#   # or
#   bash sandbox/setup-sandbox.sh

set -euo pipefail

WORKSPACE="${HOME}/nanoclaw-workspace"
SANDBOX_NAME="shell-nanoclaw-workspace"
TEMPLATE="gabinanoclaw/nanoclaw-sandbox:latest"
PLUGIN_URL="https://raw.githubusercontent.com/qwibitai/nanoclaw/main/sandbox/docker-plugin"

echo ""
echo "=== NanoClaw Docker Sandbox Setup ==="
echo ""

# ── Preflight ──────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker not found."
  echo "Install Docker Desktop 4.40+: https://www.docker.com/products/docker-desktop/"
  exit 1
fi

if ! docker sandbox version &>/dev/null; then
  echo "ERROR: Docker sandbox not available."
  echo "Update Docker Desktop to 4.40+ and enable sandbox support."
  exit 1
fi

# ── Remove existing sandbox if present ─────────────────────────────
if docker sandbox ls --format "{{.Name}}" 2>/dev/null | grep -q "^${SANDBOX_NAME}$"; then
  echo "Removing existing sandbox..."
  docker sandbox rm "$SANDBOX_NAME"
fi

# ── Download plugin files ──────────────────────────────────────────
mkdir -p "$WORKSPACE"
PLUGIN_DIR="${WORKSPACE}/docker-plugin"
mkdir -p "$PLUGIN_DIR"

if [ -f "$(dirname "$0" 2>/dev/null)/docker-plugin/manifest.json" ] 2>/dev/null; then
  cp "$(dirname "$0")/docker-plugin/manifest.json" "$PLUGIN_DIR/"
  cp "$(dirname "$0")/docker-plugin/network.json" "$PLUGIN_DIR/"
else
  echo "Downloading plugin files..."
  curl -fsSL "${PLUGIN_URL}/manifest.json" -o "$PLUGIN_DIR/manifest.json"
  curl -fsSL "${PLUGIN_URL}/network.json" -o "$PLUGIN_DIR/network.json"
fi

# ── Create sandbox from template with plugin ───────────────────────
echo "Creating sandbox (pulls image on first run)..."
docker sandbox create -t "$TEMPLATE" --plugin "$PLUGIN_DIR" shell "$WORKSPACE"

echo ""
echo "========================================="
echo "  Sandbox created!"
echo "========================================="
echo ""
echo "Now run:"
echo ""
echo "  docker sandbox run ${SANDBOX_NAME}"
echo ""
echo "Auto-setup runs on first login (~3-5 min)."
echo "When done: claude  then  /setup"
echo ""
