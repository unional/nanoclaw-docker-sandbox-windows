#!/usr/bin/env bash
# setup-sandbox.sh — Set up NanoClaw in a Docker AI Sandbox.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/qwibitai/nanoclaw/main/sandbox/setup-sandbox.sh | bash
#   # or
#   bash sandbox/setup-sandbox.sh

set -euo pipefail

# WSL: Docker Desktop can't see WSL filesystem (/home/...).
# Use Windows user profile path so Docker can mount the workspace.
if grep -qi microsoft /proc/version 2>/dev/null; then
  WIN_USER=$(cmd.exe /c "echo %USERNAME%" </dev/null 2>/dev/null | tr -d '\r\n')
  WORKSPACE="/mnt/c/Users/${WIN_USER}/nanoclaw-workspace"
  DOCKER_WORKSPACE=$(wslpath -w "$WORKSPACE")
else
  WORKSPACE="${HOME}/nanoclaw-workspace"
  DOCKER_WORKSPACE="$WORKSPACE"
fi
SANDBOX_NAME="claude-nanoclaw-workspace"
REPO_URL="https://github.com/gabi-simons/nanoclaw.git"
REPO_BRANCH="feature/sandbox-setup-script"

# When piped via curl|bash, stdin is the script itself.
# Redirect stdin for commands that might consume it.

echo ""
echo "=== NanoClaw Docker Sandbox Setup ==="
echo ""

# ── Preflight ──────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker not found."
  echo "Install Docker Desktop 4.40+: https://www.docker.com/products/docker-desktop/"
  exit 1
fi

if ! docker sandbox version </dev/null &>/dev/null; then
  echo "ERROR: Docker sandbox not available."
  echo "Update Docker Desktop 4.40+ and enable sandbox support."
  exit 1
fi

# ── Remove existing sandbox if present ─────────────────────────────
if docker sandbox ls --format "{{.Name}}" </dev/null 2>/dev/null | grep -q "^${SANDBOX_NAME}$"; then
  echo "Removing existing sandbox..."
  docker sandbox rm "$SANDBOX_NAME" </dev/null
fi

# ── Clone NanoClaw on host ─────────────────────────────────────────
if [ -f "${WORKSPACE}/package.json" ]; then
  echo "NanoClaw already cloned."
else
  echo "Cloning NanoClaw..."
  git clone -b "$REPO_BRANCH" "$REPO_URL" "$WORKSPACE" </dev/null
fi

# ── Create sandbox using Claude agent type ─────────────────────────
echo "Creating sandbox..."
echo y | docker sandbox create claude "$DOCKER_WORKSPACE"

# ── Configure proxy bypass for WhatsApp + Telegram ─────────────────
echo "Configuring network bypass..."
docker sandbox network proxy "$SANDBOX_NAME" \
  --bypass-host "api.telegram.org" \
  --bypass-host "*.telegram.org" \
  --bypass-host "*.whatsapp.com" \
  --bypass-host "*.whatsapp.net" </dev/null

echo ""
echo "========================================="
echo "  Sandbox created!"
echo "========================================="
echo ""
echo "Run this to start:"
echo ""
echo "  docker sandbox run $SANDBOX_NAME"
echo ""
echo "Type /setup when Claude Code starts."
echo ""
