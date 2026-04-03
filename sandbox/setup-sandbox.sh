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
REPO_URL="https://github.com/qwibitai/nanoclaw.git"

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

# ── Clone NanoClaw on host ─────────────────────────────────────────
mkdir -p "$WORKSPACE"

if [ -f "${WORKSPACE}/nanoclaw/package.json" ]; then
  echo "NanoClaw already cloned."
else
  echo "Cloning NanoClaw..."
  git clone "$REPO_URL" "${WORKSPACE}/nanoclaw"
fi

PLUGIN_DIR="${WORKSPACE}/nanoclaw/sandbox/docker-plugin"

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
echo "Then inside the sandbox:"
echo ""
echo "  bash \$(df -h | grep virtiofs | awk '{print \$NF}')/nanoclaw/sandbox/init.sh"
echo ""
echo "When done: claude  then  /setup"
echo ""
