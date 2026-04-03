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

# ── Create sandbox from template ──────────────────────────────────
mkdir -p "$WORKSPACE"
echo "Creating sandbox (pulls image on first run)..."
docker sandbox create -t "$TEMPLATE" shell "$WORKSPACE"

# ── Configure proxy bypass for WhatsApp ────────────────────────────
docker sandbox network proxy "$SANDBOX_NAME" \
  --bypass-host "*.whatsapp.com" \
  --bypass-host "*.whatsapp.net" 2>/dev/null || true

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
