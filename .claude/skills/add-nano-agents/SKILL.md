---
name: add-nano-agents
description: Register a new NanoClaw agent (group) interactively. Detects available channels, looks up known chats, prompts for JID and settings, runs the registration CLI, optionally creates a custom CLAUDE.md, and restarts NanoClaw.
triggers:
  - add nano agent
  - register agent
  - add agent
  - new agent
  - register group
  - add group
---

# Add Nano Agent

This skill registers a new NanoClaw agent (group) interactively. It detects what channels are configured, looks up known chats, guides you through picking a JID and settings, runs the registration CLI, optionally scaffolds a `groups/<folder>/CLAUDE.md`, and restarts NanoClaw.

---

## Phase 1: Detect Current State

Run these checks:

```bash
# 1. Which channel bots are configured
grep -E "^(DISCORD_BOT_TOKEN|TELEGRAM_BOT_TOKEN|SLACK_BOT_TOKEN)" .env 2>/dev/null || echo "(none)"

# 2. WhatsApp: check for auth store
ls store/auth/ 2>/dev/null && echo "whatsapp_auth_present" || echo "whatsapp_auth_absent"

# 3. ASSISTANT_NAME for trigger default
grep "^ASSISTANT_NAME" .env 2>/dev/null | cut -d= -f2

# 4. List already registered groups
sqlite3 store/messages.db "SELECT jid, name, folder, is_main FROM registered_groups ORDER BY added_at" 2>/dev/null || echo "(none registered)"
```

Display the results so the user can see what's connected and what's already registered.

Use `AskUserQuestion` to ask (in a single question with multiple parts):

1. **Which channel?** List only those with credentials present (WhatsApp if auth present, Discord/Telegram/Slack if token found). If only one is available, name it and confirm.
2. **What is this agent for?** (free-form description — used to suggest a folder name and CLAUDE.md content)
3. **Agent type?** Main agent (trusted, no trigger required, full project access) or group agent (trigger required, isolated sandbox)?

---

## Phase 2: Get the JID

Branch by channel:

### WhatsApp

Query the `chats` table for known groups/contacts not yet registered:

```bash
sqlite3 store/messages.db \
  "SELECT c.jid, c.name FROM chats c LEFT JOIN registered_groups r ON c.jid = r.jid WHERE r.jid IS NULL AND c.is_group = 1 ORDER BY c.name" 2>/dev/null
```

Show the numbered list. Ask the user to pick by number or enter a JID manually.

JID formats:
- Group: `120363XXXXXXXX@g.us`
- 1-on-1: `+1XXXXXXXXXX@s.whatsapp.net`

> **Tip — JID not in list?** Have someone send a message to that group/contact first so NanoClaw discovers it.

### Discord

Ask the user to:
1. Enable Developer Mode: User Settings → Advanced → Developer Mode
2. Right-click the target channel → Copy Channel ID

If multiple Discord bots are configured (multiple `DISCORD_BOT_TOKEN_*` entries), ask which bot should handle this channel.

JID formats:
- Default bot: `dc:<channelId>`
- Named bot: `dc:<botname>:<channelId>`

### Telegram

Ask the user for the chat ID (e.g. from a `/chatid` bot command or Telegram's API).

JID format: `tg:<chatId>`

### Slack

Ask the user for the channel ID (visible in channel settings URL or the "Copy link" menu).

JID format: `sl:<channelId>`

---

## Phase 3: Configure the Agent

Read `ASSISTANT_NAME` from `.env`:

```bash
grep "^ASSISTANT_NAME" .env | cut -d= -f2 | tr -d '"' | tr -d "'"
```

Derive defaults from the user's description and the JID type, then confirm with `AskUserQuestion`:

| Setting | Default | Notes |
|---------|---------|-------|
| Display name | From chat metadata or user input | e.g. `"MyServer #general"` |
| Folder name | `{channel}_{sanitized-purpose}` | e.g. `discord_dev-team`, `whatsapp_family` — alphanumeric, hyphens, underscores only |
| Trigger | `@<ASSISTANT_NAME>` | Read from `.env`; only matters when trigger required |
| Trigger required | `true` for groups, `false` for 1-on-1 | Auto-detect from JID type; override if user requested main agent |
| Is main | `false` unless explicitly requested | Only one main agent recommended |

Present the proposed values clearly and ask the user to confirm or correct before continuing.

---

## Phase 4: Register the Agent

Run the appropriate registration command based on the resolved settings.

**Group agent (trigger required):**
```bash
npx tsx setup/index.ts --step register -- \
  --jid "<jid>" \
  --name "<display-name>" \
  --folder "<folder>" \
  --trigger "@<ASSISTANT_NAME>" \
  --channel <channel>
```

**1-on-1 or no-trigger agent:**
```bash
npx tsx setup/index.ts --step register -- \
  --jid "<jid>" \
  --name "<display-name>" \
  --folder "<folder>" \
  --trigger "@<ASSISTANT_NAME>" \
  --channel <channel> \
  --no-trigger-required
```

**Main agent:**
```bash
npx tsx setup/index.ts --step register -- \
  --jid "<jid>" \
  --name "<display-name>" \
  --folder "<folder>" \
  --trigger "@<ASSISTANT_NAME>" \
  --channel <channel> \
  --no-trigger-required --is-main
```

Confirm registration succeeded:
```bash
sqlite3 store/messages.db \
  "SELECT jid, name, folder, is_main, requires_trigger FROM registered_groups WHERE folder='<folder>'"
```

If the command fails, check:
- Folder name: must be alphanumeric with hyphens/underscores only, no spaces.
- JID prefix: must match the configured channel (`dc:` for Discord, `tg:` for Telegram, `sl:` for Slack, bare JID for WhatsApp).

---

## Phase 5: Optional — Custom CLAUDE.md

Ask the user: "Do you want to give this agent a custom role or specific instructions?"

If **yes**, create `groups/<folder>/CLAUDE.md` using this template (fill in details from Phase 1 responses):

```markdown
# <ASSISTANT_NAME> — <purpose>

<!-- Inherits base capabilities from groups/global/CLAUDE.md -->

## Role

<One paragraph describing what this agent specialises in, based on the user's description.>

## Focus Areas

- <Derived from user's stated purpose>

## Notes

- <Any specific constraints or preferences the user mentioned>
```

Keep it brief — `groups/global/CLAUDE.md` already covers tools, formatting, memory, and scheduling. Only add what's specific to this group.

If **no**, skip. The agent will use `groups/global/CLAUDE.md` automatically.

---

## Phase 6: Restart and Verify

```bash
pkill -f "tsx src/index" 2>/dev/null; sleep 1
node node_modules/tsx/dist/cli.mjs src/index.ts > /tmp/nanoclaw-dev.log 2>&1 &
sleep 15 && tail -20 /tmp/nanoclaw-dev.log
```

Check the log output for the new group appearing at startup.

Tell the user:

> Your new agent **\<name\>** (`<folder>`) is registered.
> - Channel: `<channel>`
> - JID: `<jid>`
> - Trigger: `@<ASSISTANT_NAME>` (if trigger required) or "responds to all messages"
>
> Send a message in the channel to test it.

---

## Troubleshooting

- **JID not found in chats table (WhatsApp):** Have someone send a message to the group/contact first so NanoClaw discovers it, then re-run this skill.
- **Wrong channel claimed:** Verify the JID prefix matches the bot — `dc:` = default Discord bot, `dc:<name>:` = named Discord bot, `tg:` = Telegram, `sl:` = Slack, bare JID = WhatsApp.
- **Folder name rejected:** Must be alphanumeric with hyphens/underscores only — no spaces or special characters.
- **Agent not responding:** Check trigger pattern, confirm `requires_trigger` in the DB matches expectations, and verify the correct bot was invited to the channel.
- **Multiple Discord bots:** If the wrong bot was assigned, re-register with the correct `dc:<botname>:<channelId>` JID format.
