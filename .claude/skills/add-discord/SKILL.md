---
name: add-discord
description: Add Discord bot channel integration to NanoClaw.
---

# Add Discord Channel

This skill adds Discord support to NanoClaw and walks through interactive setup. It also handles adding additional bots with different permissions to an existing Discord setup.

## Phase 1: Detect Current State

Run these checks to understand what is already in place:

```bash
# 1. Check if Discord code is merged
ls src/channels/discord.ts 2>/dev/null && echo "CODE_EXISTS" || echo "CODE_MISSING"

# 2. Check which bot tokens are configured
grep "DISCORD_BOT_TOKEN" .env 2>/dev/null || echo "(none)"

# 3. Check registered Discord channels
sqlite3 store/messages.db "SELECT jid, name, folder FROM registered_groups WHERE jid LIKE 'dc:%'" 2>/dev/null || echo "(none)"
```

**Branch based on results:**

| Scenario | Code exists? | Token in .env? | Go to |
|----------|-------------|----------------|-------|
| Fresh install | No | No | Phase 2 (merge code), then Phase 3 |
| Code merged, not configured | Yes | No | Phase 3 |
| First bot already running | Yes | `DISCORD_BOT_TOKEN` only | Ask user intent → Phase 5 (add bot) or Phase 4 (add channel) |
| Multiple bots already set up | Yes | Multiple tokens | Ask user intent → Phase 5 (add bot) or Phase 4 (add channel) |

**Ask the user:**

If a bot is already configured, use `AskUserQuestion`:

> I can see you already have a Discord bot set up. What would you like to do?
> 1. **Add another bot** with different permissions (reduces security exposure)
> 2. **Register an additional channel** on an existing bot

If no bot exists yet, proceed to Phase 2.

---

## Phase 2: Apply Code Changes

> Skip this phase if `src/channels/discord.ts` already exists.

### Ensure channel remote

```bash
git remote -v
```

If `discord` is missing, add it:

```bash
git remote add discord https://github.com/qwibitai/nanoclaw-discord.git
```

### Merge the skill branch

```bash
git fetch discord main
git merge discord/main || {
  git checkout --theirs package-lock.json
  git add package-lock.json
  git merge --continue
}
```

This merges in:
- `src/channels/discord.ts` (DiscordChannel class with self-registration via `registerChannel`)
- `src/channels/discord.test.ts` (unit tests with discord.js mock)
- `import './discord.js'` appended to the channel barrel file `src/channels/index.ts`
- `discord.js` npm dependency in `package.json`
- `DISCORD_BOT_TOKEN` in `.env.example`

If the merge reports conflicts, resolve them by reading the conflicted files and understanding the intent of both sides.

### Validate code changes

```bash
npm install
npm run build
npx vitest run src/channels/discord.test.ts
```

All tests must pass and the build must be clean before proceeding.

---

## Phase 3: Configure First Bot

> Skip this phase if a bot token is already in `.env`.

### Create the Discord bot

Tell the user:

> I need you to create a Discord bot:
>
> 1. Go to the [Discord Developer Portal](https://discord.com/developers/applications)
> 2. Click **New Application** and give it a name (e.g., "Andy Assistant")
> 3. Go to the **Bot** tab on the left sidebar
> 4. Click **Reset Token** to generate a bot token — copy it immediately (shown only once)
> 5. Under **Privileged Gateway Intents**, enable:
>    - **Message Content Intent** (required to read message text)
>    - **Server Members Intent** (optional, for member display names)
> 6. Go to **OAuth2** > **URL Generator**:
>    - Scopes: select `bot`
>    - Bot Permissions: select `Send Messages`, `Read Message History`, `View Channels`
>    - Copy the generated URL and open it to invite the bot to your server

Wait for the user to provide the token.

### Configure environment

Add to `.env`:

```
DISCORD_BOT_TOKEN=<their-token>
```

Sync to the container environment:

```bash
mkdir -p data/env && cp .env data/env/env
```

### Build and restart

```bash
npm run build
launchctl kickstart -k gui/$(id -u)/com.nanoclaw
```

Then proceed to Phase 4 to register a channel.

---

## Phase 4: Register a Channel

### Get the channel ID

Tell the user:

> To get the channel ID:
>
> 1. In Discord, go to **User Settings** > **Advanced** > enable **Developer Mode**
> 2. Right-click the text channel you want the bot to respond in
> 3. Click **Copy Channel ID**
>
> The channel ID is a long number like `1234567890123456`.

Wait for the user to provide the channel ID.

### Determine which bot handles this channel

If only one bot token is configured (`DISCORD_BOT_TOKEN`), use the **default** bot — JID format: `dc:<channelId>`.

If multiple bots are configured, ask the user which bot should handle this channel. The bot name comes from the env var suffix:

| Env var | Bot name | JID format |
|---------|----------|------------|
| `DISCORD_BOT_TOKEN` | default | `dc:<channelId>` |
| `DISCORD_BOT_TOKEN_READONLY` | readonly | `dc:readonly:<channelId>` |
| `DISCORD_BOT_TOKEN_ADMIN` | admin | `dc:admin:<channelId>` |

Make sure the chosen bot has been invited to the server containing that channel.

### Register the channel

For a **main channel** (responds to all messages, no @mention required):

```bash
# Default bot
npx tsx setup/index.ts --step register -- \
  --jid "dc:<channel-id>" \
  --name "<server-name> #<channel-name>" \
  --folder "discord_main" \
  --trigger "@${ASSISTANT_NAME}" \
  --channel discord \
  --no-trigger-required --is-main

# Named bot (e.g. readonly)
npx tsx setup/index.ts --step register -- \
  --jid "dc:readonly:<channel-id>" \
  --name "<server-name> #<channel-name>" \
  --folder "discord_readonly_main" \
  --trigger "@${ASSISTANT_NAME}" \
  --channel discord_readonly \
  --no-trigger-required --is-main
```

For an **additional channel** (trigger required):

```bash
# Default bot
npx tsx setup/index.ts --step register -- \
  --jid "dc:<channel-id>" \
  --name "<server-name> #<channel-name>" \
  --folder "discord_<channel-name>" \
  --trigger "@${ASSISTANT_NAME}" \
  --channel discord

# Named bot
npx tsx setup/index.ts --step register -- \
  --jid "dc:<botname>:<channel-id>" \
  --name "<server-name> #<channel-name>" \
  --folder "discord_<botname>_<channel-name>" \
  --trigger "@${ASSISTANT_NAME}" \
  --channel discord_<botname>
```

---

## Phase 5: Add an Additional Bot

This phase is for adding a **second (or third) Discord bot** with different Discord permissions. Each bot uses a separate token and gets its own name. If one token is ever compromised, the attacker only has access to the channels that specific bot was invited to.

### Choose a bot name and permission set

Ask the user what they want this bot to do, then suggest a name and permission set:

| Use case | Suggested name | Recommended Discord permissions |
|----------|---------------|--------------------------------|
| General assistant (full) | `admin` | Send Messages, Read Message History, View Channels, Manage Messages |
| Limited assistant | `limited` | Send Messages, Read Message History, View Channels |
| Read-only monitor | `monitor` | View Channels, Read Message History (no Send Messages) |
| Specific server only | any descriptive name | Same as chosen tier, scoped to that server |

### Create the new bot application

Tell the user:

> Create a new Discord application for this bot:
>
> 1. Go to the [Discord Developer Portal](https://discord.com/developers/applications)
> 2. Click **New Application** — give it a distinct name (e.g., "Andy Read-Only")
> 3. Go to the **Bot** tab > click **Reset Token** — copy it immediately
> 4. Under **Privileged Gateway Intents**, enable **Message Content Intent** (and optionally **Server Members Intent**)
> 5. Go to **OAuth2** > **URL Generator**:
>    - Scopes: `bot`
>    - Bot Permissions: select only the permissions appropriate for this bot's role (see table above)
>    - Copy the invite URL and add the bot to the target server(s)
>
> Keep this token separate from your main bot token — they must never be the same.

Wait for the user to provide the token and their chosen bot name (e.g., `readonly`).

### Add the token to `.env`

The env var name is `DISCORD_BOT_TOKEN_<BOTNAME>` (uppercase):

```
# .env
DISCORD_BOT_TOKEN=<existing-default-token>
DISCORD_BOT_TOKEN_READONLY=<new-token>
```

NanoClaw automatically discovers all `DISCORD_BOT_TOKEN_*` vars at startup and registers one bot instance per token.

Sync to container:

```bash
cp .env data/env/env
```

### Build and restart

```bash
npm run build
launchctl kickstart -k gui/$(id -u)/com.nanoclaw
```

In the startup log you should now see two Discord bot connection messages:

```
Discord bot: Andy Assistant#1234
Discord bot: Andy Read-Only#5678
```

### Register channels for the new bot

Proceed to Phase 4, choosing the new bot name when prompted.

---

## Phase 6: Verify

Tell the user:

> Send a message in your registered Discord channel:
> - For a main channel: any message works
> - For non-main channels: @mention the bot
>
> The bot should respond within a few seconds.

Check logs if needed:

```bash
tail -f logs/nanoclaw.log
```

---

## Troubleshooting

### Bot not responding

1. Check the token is in `.env` AND synced to `data/env/env`
2. Check the channel is registered:
   ```bash
   sqlite3 store/messages.db "SELECT jid, name, folder FROM registered_groups WHERE jid LIKE 'dc:%'"
   ```
3. Confirm the JID prefix matches the bot — named bots use `dc:<botname>:<channelId>`:
   ```bash
   # default bot channel
   dc:1234567890123456
   # named bot (readonly) channel
   dc:readonly:1234567890123456
   ```
4. For non-main channels: message must include the trigger (@mention the bot)
5. Service is running: `launchctl list | grep nanoclaw`
6. Verify the correct bot was invited to the server (each bot needs its own invite)

### Wrong bot responding (or not responding)

Each bot only owns JIDs that match its prefix. If a channel is registered with `dc:readonly:...` but you are messaging a channel that only the default bot is in, there will be no response. Make sure:
- The channel JID prefix matches the bot token used (`dc:` = default, `dc:<name>:` = named)
- The correct bot application was invited to that Discord server

### Message Content Intent not enabled

If the bot connects but can't read messages:
1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Select the **specific application** for this bot > **Bot** tab
3. Enable **Message Content Intent**
4. Restart NanoClaw

### Bot only responds to @mentions

Default behavior for non-main channels (`requiresTrigger: true`). To change, re-register the channel with `--no-trigger-required` or `--is-main`.

---

## After Setup

The Discord channel supports:
- Multiple bots with isolated JID namespaces (`dc:` vs `dc:<name>:`)
- Text messages in registered channels
- Attachment descriptions (images, videos, files shown as placeholders)
- PDF downloads for registered groups
- Reply context (shows who the user is replying to)
- @mention translation (Discord `<@botId>` → NanoClaw trigger format)
- Message splitting for responses over 2000 characters
- Typing indicators while the agent processes
