#!/usr/bin/env bash
# setup-sandbox.sh — Create a Docker AI Sandbox with NanoClaw ready to go.
#
# Run directly:  bash sandbox/setup-sandbox.sh [--workspace <path>]
# Run via curl:  curl -fsSL https://raw.githubusercontent.com/qwibitai/nanoclaw/main/sandbox/setup-sandbox.sh | bash
#
# After this script finishes:
#   docker sandbox run shell-nanoclaw-workspace
#   cd <workspace>/nanoclaw
#   claude
#   /setup

set -euo pipefail

WORKSPACE="${HOME}/nanoclaw-workspace"
REPO_URL="https://github.com/qwibitai/nanoclaw.git"
RAW_BASE="https://raw.githubusercontent.com/qwibitai/nanoclaw/main/sandbox"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

SANDBOX_NAME="shell-$(basename "$WORKSPACE")"

log()  { echo "==> $*"; }
step() { echo ""; echo "--- Step $1: $2 ---"; }
run_in_sandbox() { docker sandbox exec "$SANDBOX_NAME" bash -c "$1"; }

# ── Step 1: Preflight ──────────────────────────────────────────────
step 1 "Preflight checks"

if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker not found. Install Docker Desktop 4.40+ first."
  exit 1
fi

if ! docker sandbox version &>/dev/null; then
  echo "ERROR: Docker sandbox not available. Need Docker Desktop 4.40+ with sandbox support."
  exit 1
fi

log "Docker: $(docker version --format '{{.Client.Version}}' 2>/dev/null)"
log "Sandbox: $(docker sandbox version 2>/dev/null | head -1)"

# ── Step 2: Create workspace and sandbox ────────────────────────────
step 2 "Creating sandbox"

mkdir -p "$WORKSPACE"

# Download sandbox-patch.sh into workspace (works for both local and curl usage)
if [ -f "$(dirname "$0" 2>/dev/null)/sandbox-patch.sh" ] 2>/dev/null; then
  cp "$(dirname "$0")/sandbox-patch.sh" "$WORKSPACE/sandbox-patch.sh"
  log "Copied sandbox-patch.sh from local repo"
else
  log "Downloading sandbox-patch.sh..."
  curl -fsSL "${RAW_BASE}/sandbox-patch.sh" -o "$WORKSPACE/sandbox-patch.sh"
fi

# Check if sandbox already exists
if docker sandbox ls --format "{{.Name}}" 2>/dev/null | grep -q "^${SANDBOX_NAME}$"; then
  log "Sandbox '$SANDBOX_NAME' already exists"
  read -rp "Remove and recreate? [y/N] " ans
  if [[ "$ans" =~ ^[Yy] ]]; then
    docker sandbox rm "$SANDBOX_NAME"
    log "Removed old sandbox"
  else
    log "Reusing existing sandbox"
  fi
fi

if ! docker sandbox ls --format "{{.Name}}" 2>/dev/null | grep -q "^${SANDBOX_NAME}$"; then
  log "Creating sandbox '$SANDBOX_NAME' with workspace '$WORKSPACE'..."
  docker sandbox create shell "$WORKSPACE"
  log "Sandbox created"
fi

# ── Step 3: Configure proxy bypass (for WhatsApp) ──────────────────
step 3 "Configuring proxy bypass for WhatsApp"

docker sandbox network proxy "$SANDBOX_NAME" \
  --bypass-host web.whatsapp.com \
  --bypass-host "*.whatsapp.com" \
  --bypass-host "*.whatsapp.net" 2>/dev/null || true

log "Proxy bypass configured"

# ── Step 4: Find workspace path inside sandbox ─────────────────────
step 4 "Detecting workspace mount inside sandbox"

SANDBOX_WORKSPACE=$(run_in_sandbox "df -h 2>/dev/null | grep virtiofs | head -1 | awk '{print \$NF}'")

if [[ -z "$SANDBOX_WORKSPACE" ]]; then
  echo "ERROR: Could not detect workspace mount inside sandbox"
  exit 1
fi

log "Workspace inside sandbox: $SANDBOX_WORKSPACE"

# ── Step 5: Install prerequisites ──────────────────────────────────
step 5 "Installing prerequisites inside sandbox"

run_in_sandbox "sudo apt-get update -qq && sudo apt-get install -y -qq build-essential python3 >/dev/null 2>&1 && npm config set strict-ssl false && echo OK"
log "Prerequisites installed"

# ── Step 6: Clone NanoClaw ─────────────────────────────────────────
step 6 "Cloning NanoClaw"

NANOCLAW_DIR="${SANDBOX_WORKSPACE}/nanoclaw"

# Check if already cloned
if run_in_sandbox "test -f '${NANOCLAW_DIR}/package.json' && echo YES || echo NO" | grep -q YES; then
  log "NanoClaw already cloned at ${NANOCLAW_DIR}"
else
  # Clone to home first (virtiofs can corrupt git pack files), then move
  run_in_sandbox "cd /home/agent && git clone ${REPO_URL} 2>&1 && mv /home/agent/nanoclaw '${NANOCLAW_DIR}'"
  log "Cloned NanoClaw to ${NANOCLAW_DIR}"
fi

# ── Step 7: Install npm dependencies ───────────────────────────────
step 7 "Installing npm dependencies"

run_in_sandbox "cd '${NANOCLAW_DIR}' && npm install 2>&1 && npm install https-proxy-agent 2>&1" | tail -5
log "Dependencies installed"

# ── Step 8: Apply sandbox patches ──────────────────────────────────
step 8 "Applying sandbox patches"

# Fix Windows line endings on the patch script
run_in_sandbox "sed -i 's/\r$//' '${SANDBOX_WORKSPACE}/sandbox-patch.sh' 2>/dev/null || true"

run_in_sandbox "cd '${NANOCLAW_DIR}' && bash '${SANDBOX_WORKSPACE}/sandbox-patch.sh' 2>&1" || true
log "Patches applied"

# ── Step 9: Build NanoClaw ─────────────────────────────────────────
step 9 "Building NanoClaw"

run_in_sandbox "cd '${NANOCLAW_DIR}' && npm run build 2>&1" | tail -3
log "NanoClaw built"

# ── Step 10: Build agent container ─────────────────────────────────
step 10 "Building agent container image"

run_in_sandbox "cd '${NANOCLAW_DIR}' && bash container/build.sh 2>&1" | tail -5
log "Agent container built"

# ── Step 11: Install Claude Code ───────────────────────────────────
step 11 "Installing Claude Code"

run_in_sandbox "npm install -g @anthropic-ai/claude-code 2>&1" | tail -3
log "Claude Code installed"

# ── Done ───────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo "  Sandbox ready!"
echo "========================================="
echo ""
echo "Enter the sandbox:"
echo "  docker sandbox run ${SANDBOX_NAME}"
echo ""
echo "Then inside:"
echo "  cd ${SANDBOX_WORKSPACE}/nanoclaw"
echo "  claude"
echo "  /setup"
echo ""
