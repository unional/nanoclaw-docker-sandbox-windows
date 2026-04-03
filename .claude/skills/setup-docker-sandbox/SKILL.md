---
name: setup-docker-sandbox
description: Set up NanoClaw inside a Docker AI Sandbox. Alternative to /setup that provides full isolation via Docker Desktop's sandbox microVMs. Triggers on "docker sandbox", "sandbox setup", "setup in sandbox", "setup docker sandbox".
---

# NanoClaw Docker Sandbox Setup

Set up NanoClaw inside a Docker AI Sandbox — an isolated microVM with its own Docker daemon, proxy-managed API keys, and persistent state. This is an alternative to `/setup` for users who want full isolation.

Setup uses `npx tsx setup/index.ts --step sandbox -- --action <name>` for host-side steps, and `docker sandbox exec` or `docker sandbox run` for commands inside the sandbox. Steps emit structured status blocks to stdout. Verbose logs go to `logs/setup.log`.

**Principle:** When something is broken or missing, fix it. Don't tell the user to go fix it themselves unless it genuinely requires their manual action (e.g. scanning a QR code, entering a pairing code). Ask the user for permission when needed, then do the work.

**UX Note:** Use `AskUserQuestion` for all user-facing questions.

## 1. Prerequisites

Run `npx tsx setup/index.ts --step sandbox -- --action preflight` and parse the status block.

- If DOCKER_INSTALLED=false → Docker Desktop is required. AskUserQuestion: "Docker Desktop 4.40+ is required. Would you like installation instructions?" If yes:
  - macOS: `brew install --cask docker`, then `open -a Docker`
  - Windows: direct to https://docs.docker.com/desktop/install/windows-install/
  - After installing, re-run the preflight step.
- If SANDBOX_AVAILABLE=false → Docker Sandbox support not available. The user may need Docker Desktop 4.40+ or to enable the sandboxes feature. AskUserQuestion: "Docker Desktop 4.40+ with sandbox support is required. Is Docker Desktop up to date?"
- If EXISTING_SANDBOXES is not "none" → Note existing sandboxes. If one is NanoClaw-related, offer to reuse it.

## 2. Choose Approach

AskUserQuestion: "Quick setup from template (recommended, ~3 min) or manual setup from scratch (~10 min)?"

- **Template:** Uses pre-built image `olegselajev241/nanoclaw-sandbox:latest` with dependencies cached. Faster.
- **Manual:** Builds everything from scratch inside a blank sandbox. More flexible.

Also AskUserQuestion: "Which channels do you want to enable?"
- WhatsApp (QR code or pairing code authentication)
- Telegram (bot token from @BotFather)

Record selections for steps 5 and 6.

## 3. Create Sandbox

### 3a. Create workspace and sandbox

**Template mode:**
```
npx tsx setup/index.ts --step sandbox -- --action create --template olegselajev241/nanoclaw-sandbox:latest --workspace ~/nanoclaw-workspace
```

**Manual mode:**
```
npx tsx setup/index.ts --step sandbox -- --action create --workspace ~/nanoclaw-workspace
```

Parse the status block:
- If STATUS=exists → AskUserQuestion: "A sandbox already exists. Reuse it, or remove and recreate?" If remove: `docker sandbox rm shell-nanoclaw-workspace` then retry.
- If STATUS=failed → Read the ERROR field and diagnose.

Record the sandbox NAME from the output (default: `shell-nanoclaw-workspace`).

### 3b. Configure proxy bypass (WhatsApp only)

Skip if user is only using Telegram.

```
npx tsx setup/index.ts --step sandbox -- --action proxy-bypass --name shell-nanoclaw-workspace
```

This configures the sandbox proxy to bypass MITM inspection for WhatsApp hosts. WhatsApp's Noise protocol rejects MITM connections. Telegram does not need this.

## 4. Initialize NanoClaw

Run `npx tsx setup/index.ts --step sandbox -- --action init --name shell-nanoclaw-workspace` and parse the status block.

### Template mode (MODE=template)

The template's auto-init runs on first interactive login. Tell the user:

"Enter the sandbox to trigger auto-setup (~3-5 min). Run:"
```
docker sandbox run shell-nanoclaw-workspace
```

"Wait for the 'Setup complete!' message, then exit with Ctrl+D."

After user confirms, verify initialization:
```
npx tsx setup/index.ts --step sandbox -- --action status --name shell-nanoclaw-workspace
```

If NANOCLAW_INITIALIZED=false → Tell user to re-enter the sandbox and run `nanoclaw-init` manually.

### Manual mode (MODE=manual)

Run these commands inside the sandbox. Use `npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd <command>` for each step.

**4a. Install prerequisites:**
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "sudo apt-get update && sudo apt-get install -y build-essential python3 && npm config set strict-ssl false"
```

**4b. Clone NanoClaw:**
Clone to home first (virtiofs can corrupt git pack files during clone), then move to workspace:
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "cd ~ && git clone https://github.com/qwibitai/nanoclaw.git && WORKSPACE=\$(df -h | grep virtiofs | awk '{print \$NF}' | head -1) && mv ~/nanoclaw \"\$WORKSPACE/nanoclaw\""
```

**4c. Install dependencies:**
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "WORKSPACE=\$(cat /home/agent/.nanoclaw-workspace 2>/dev/null || df -h | grep virtiofs | awk '{print \$NF}' | head -1) && cd \"\$WORKSPACE/nanoclaw\" && npm install && npm install https-proxy-agent"
```

**4d. Apply sandbox patches:**
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "WORKSPACE=\$(cat /home/agent/.nanoclaw-workspace 2>/dev/null || df -h | grep virtiofs | awk '{print \$NF}' | head -1) && cd \"\$WORKSPACE/nanoclaw\" && bash sandbox/sandbox-patch.sh"
```

If sandbox-patch.sh is not inside the repo (no sandbox/ dir), it was copied to the workspace root by the create step. Use:
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "WORKSPACE=\$(cat /home/agent/.nanoclaw-workspace 2>/dev/null || df -h | grep virtiofs | awk '{print \$NF}' | head -1) && cd \"\$WORKSPACE/nanoclaw\" && bash \"\$WORKSPACE/sandbox-patch.sh\""
```

**4e. Build NanoClaw and agent container:**
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "WORKSPACE=\$(cat /home/agent/.nanoclaw-workspace 2>/dev/null || df -h | grep virtiofs | awk '{print \$NF}' | head -1) && cd \"\$WORKSPACE/nanoclaw\" && npm run build && bash container/build.sh"
```

## 5. Set Up Channels

AskUserQuestion (if not already answered in step 2): Which channels?

For each selected channel, the approach depends on whether the sandbox has the `setup-channel` helper (template mode) or not (manual mode).

### Telegram

AskUserQuestion: "Do you have a Telegram bot token from @BotFather? If not, create one: open @BotFather in Telegram, send /newbot, follow prompts, and paste the token here."

AskUserQuestion: "What is your Telegram chat ID? Send any message to your bot, then run `/chatid` in the chat to get it."

**Template mode (setup-channel available):**
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "WORKSPACE=\$(cat /home/agent/.nanoclaw-workspace 2>/dev/null || df -h | grep virtiofs | awk '{print \$NF}' | head -1) && cd \"\$WORKSPACE/nanoclaw\" && bash sandbox/setup-channel.sh telegram --token <TOKEN> --chat-id <CHAT_ID>"
```

**Manual mode:**
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "WORKSPACE=\$(cat /home/agent/.nanoclaw-workspace 2>/dev/null || df -h | grep virtiofs | awk '{print \$NF}' | head -1) && cd \"\$WORKSPACE/nanoclaw\" && npx tsx scripts/apply-skill.ts .claude/skills/add-telegram && bash sandbox/sandbox-patch.sh && npm run build"
```

Then write .env:
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "WORKSPACE=\$(cat /home/agent/.nanoclaw-workspace 2>/dev/null || df -h | grep virtiofs | awk '{print \$NF}' | head -1) && cd \"\$WORKSPACE/nanoclaw\" && printf 'TELEGRAM_BOT_TOKEN=<TOKEN>\nASSISTANT_NAME=nanoclaw\nANTHROPIC_API_KEY=proxy-managed\n' > .env && mkdir -p data/env && cp .env data/env/env"
```

Then register:
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "WORKSPACE=\$(cat /home/agent/.nanoclaw-workspace 2>/dev/null || df -h | grep virtiofs | awk '{print \$NF}' | head -1) && cd \"\$WORKSPACE/nanoclaw\" && npx tsx setup/index.ts --step register --jid 'tg:<CHAT_ID>' --name 'Telegram Chat' --trigger '@nanoclaw' --folder 'telegram_main' --channel telegram --assistant-name 'nanoclaw' --is-main --no-trigger-required"
```

### WhatsApp

Ensure proxy bypass was configured in step 3b. If not, run it now.

**Apply skill and patch:**
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "WORKSPACE=\$(cat /home/agent/.nanoclaw-workspace 2>/dev/null || df -h | grep virtiofs | awk '{print \$NF}' | head -1) && cd \"\$WORKSPACE/nanoclaw\" && npx tsx scripts/apply-skill.ts .claude/skills/add-whatsapp && bash sandbox/sandbox-patch.sh && npm run build"
```

Write .env (if not already written by Telegram step):
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "WORKSPACE=\$(cat /home/agent/.nanoclaw-workspace 2>/dev/null || df -h | grep virtiofs | awk '{print \$NF}' | head -1) && cd \"\$WORKSPACE/nanoclaw\" && printf 'ASSISTANT_NAME=nanoclaw\nANTHROPIC_API_KEY=proxy-managed\n' > .env && mkdir -p data/env && cp .env data/env/env"
```

**Authenticate WhatsApp** — this requires an interactive terminal for QR code display:

AskUserQuestion: "QR code (scan with phone) or pairing code (enter phone number)?"

Tell the user to enter the sandbox interactively and run the auth command:

**QR code:**
```
docker sandbox run shell-nanoclaw-workspace
# Inside the sandbox:
cd $(cat ~/.nanoclaw-workspace)/nanoclaw && npx tsx src/whatsapp-auth.ts
```

**Pairing code:** AskUserQuestion for phone number (with country code, no +). Then:
```
docker sandbox run shell-nanoclaw-workspace
# Inside the sandbox:
cd $(cat ~/.nanoclaw-workspace)/nanoclaw && npx tsx src/whatsapp-auth.ts --pairing-code --phone <NUMBER>
```

After user confirms authentication succeeded, register the chat. AskUserQuestion for their phone number (for JID):
```
npx tsx setup/index.ts --step sandbox -- --action exec --name shell-nanoclaw-workspace --cmd "WORKSPACE=\$(cat /home/agent/.nanoclaw-workspace 2>/dev/null || df -h | grep virtiofs | awk '{print \$NF}' | head -1) && cd \"\$WORKSPACE/nanoclaw\" && npx tsx setup/index.ts --step register --jid '<PHONE>@s.whatsapp.net' --name 'My Chat' --trigger '@nanoclaw' --folder 'whatsapp_main' --channel whatsapp --assistant-name 'nanoclaw' --is-main --no-trigger-required"
```

## 6. Start NanoClaw

Tell the user to enter the sandbox and start NanoClaw:

```
docker sandbox run shell-nanoclaw-workspace
# Inside the sandbox:
cd $(cat ~/.nanoclaw-workspace)/nanoclaw && npm start
```

NanoClaw runs in the foreground. Ctrl+C to stop.

**Note on API keys:** No API key configuration needed — the sandbox proxy transparently injects the Anthropic API key. `.env` uses `ANTHROPIC_API_KEY=proxy-managed`.

## 7. Verify

After NanoClaw starts, tell the user to send a test message in their configured channel.

Check sandbox status from the host:
```
npx tsx setup/index.ts --step sandbox -- --action status --name shell-nanoclaw-workspace
```

If NANOCLAW_RUNNING=false → NanoClaw is not running inside the sandbox. Tell user to check logs inside the sandbox: `tail -f logs/nanoclaw.log`

If no response to messages:
- Check channel credentials: Telegram token in `.env`, WhatsApp creds in `store/auth/`
- Check registration: look for registered groups in the database
- Check logs for errors

## Troubleshooting

**npm install fails with SELF_SIGNED_CERT_IN_CHAIN:** Run inside sandbox: `npm config set strict-ssl false`

**Container build fails with proxy errors:** Build with explicit proxy args inside sandbox:
```
docker build --build-arg http_proxy=$http_proxy --build-arg https_proxy=$https_proxy -t nanoclaw-agent:latest container/
```

**Agent containers can't reach Anthropic API:** Verify the sandbox patches were applied. Check for `SANDBOX_PATCH_PROXY_ENV` in `src/container-runner.ts`. Check container logs for `HTTP_PROXY` env var.

**WhatsApp error 405:** Version fetch returns stale version. Verify `fetchWaVersionViaProxy` patch is applied in `src/channels/whatsapp.ts`.

**WhatsApp "Connection failed" immediately:** Proxy bypass not configured. Re-run step 3b.

**Telegram bot doesn't receive messages:** Check `HttpsProxyAgent` patch is applied in `src/channels/telegram.ts`. Disable Group Privacy in @BotFather if using in groups.

**Git clone fails with "inflate: data stream error":** Clone to a non-workspace path first, then move (virtiofs issue). The init script handles this automatically.

**Auto-init didn't run on first login:** Run `nanoclaw-init` manually inside the sandbox. If script missing, run `bash sandbox/nanoclaw-init.sh` from the NanoClaw directory.

**Re-running setup after update:** Inside sandbox: `rm ~/.nanoclaw-initialized && nanoclaw-init`

**Sandbox not found:** Run `docker sandbox ls` to list available sandboxes. The name is derived from the workspace path (e.g., `~/nanoclaw-workspace` → `shell-nanoclaw-workspace`).
