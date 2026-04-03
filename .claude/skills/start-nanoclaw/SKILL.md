---
name: start-nanoclaw
description: Start NanoClaw and verify all channels are connected. Use when NanoClaw is not running or after a restart. Handles WSL environment where systemctl is unavailable.
---

# Start NanoClaw

Start NanoClaw and confirm it is fully running with all channels connected.

## Environment Notes

- `systemctl` is not available in this WSL environment — do not try it.
- `tsx` is NOT in PATH — use `node node_modules/tsx/dist/cli.mjs` or `./start-nanoclaw.sh`. Never use `npm run dev` directly; it will fail with `tsx: not found`.
- Always `cd` to the project root before starting — `src/env.ts` uses `process.cwd()` to load `.env`. Wrong directory = no Discord/API tokens.
- Always check for an existing instance before starting to avoid `EADDRINUSE: 0.0.0.0:3001`.
- Pino logger output is heavily buffered on this filesystem (virtiofs). Proxy-bootstrap messages appear immediately; pino `INFO` lines may not appear for 60–90s. Wait the full time before concluding something is wrong.
- A background task reporting "exit code 0" does NOT mean the process died — the task wrapper exits while the NanoClaw process keeps running.
- NanoClaw may have been started as a background Claude task — its stdout will be a task output file, not `/tmp/nanoclaw-dev.log`. Always discover the actual log via the process file descriptor.
- The trigger phrase in logs is `@nano`, not `@NanoClaw`.

## Steps

### 1. Check if already running

```bash
ps aux | grep -v grep | grep -v bash | grep "tsx.*index\.ts\|node.*tsx/dist/cli"
```

**If a process is found** — go to step 1b.
**If no process is found** — go to step 2.

### 1b. Health check (already running)

Find the actual log file and read recent output:

```bash
PID=$(ps aux | grep -v grep | grep -v bash | grep "tsx.*index\.ts\|node.*tsx/dist/cli" | awk '{print $2}' | head -1)
LOG=$(readlink -f /proc/$PID/fd/1 2>/dev/null || echo "/tmp/nanoclaw-dev.log")
echo "Log: $LOG"
tail -30 "$LOG"
```

**Healthy** if: recent lines contain `INFO` entries (message processing, agent spawning, messages sent, etc.) and no fatal `ERROR` lines.

**Done — report status cleanly** (see Response Format below). Do not proceed to step 2.

**Unhealthy** if: only old lines, fatal errors, or the process is stuck. Kill and restart:
```bash
pkill -f "tsx.*index\.ts" 2>/dev/null || true
pkill -f "node.*tsx/dist/cli" 2>/dev/null || true
sleep 2
```
Then proceed to step 2.

### 2. Start NanoClaw

Use the provided start script, which handles tsx path resolution and native binding checks automatically:

```bash
cd /wsl.localhost/Ubuntu/home/unional/nanoclaw-sandbox-5865
./start-nanoclaw.sh
```

The script:
- Kills any stale instances
- Checks for `tsx` binary and runs `npm install` if missing
- Downloads `better-sqlite3` prebuilt native bindings if missing (common after fresh `npm install` on virtiofs)
- Starts `node node_modules/tsx/dist/cli.mjs src/index.ts` with output to `/tmp/nanoclaw-dev.log`
- Writes PID to `/tmp/nanoclaw.pid`

### 3. Verify fresh startup

Pino output is buffered — wait up to 90s, then check:

```bash
sleep 60 && tail -50 /tmp/nanoclaw-dev.log
```

Look for these success indicators:
- `Discord bot connected` — Discord is up (appears twice if two bots are configured)
- `Connected to WhatsApp` — WhatsApp is up
- `NanoClaw running (trigger: @nano)` — message loop is active
- `Scheduler loop started` — scheduled tasks are active
- `IPC watcher started` — IPC is active

If only proxy-bootstrap lines appear after 90s, check if the process is still alive (step 4) and wait longer.

### 4. Confirm process is still alive

```bash
ps aux | grep -v grep | grep -v bash | grep "tsx.*index\.ts\|node.*tsx/dist/cli" && echo "running" || echo "stopped"
```

## Response Format

Once health is confirmed, output a concise status line. Do not narrate investigation steps. Examples:

- "NanoClaw is running — Discord and WhatsApp connected."
- "NanoClaw started successfully — Discord (2 bots) and WhatsApp connected."
- "NanoClaw is running — Discord connected. WhatsApp reconnecting (last seen X min ago)."

List only channels that are visibly active in recent logs. Do not hedge or say "let me check...".

## Troubleshooting

**`tsx: not found` / `npm run dev` fails** — `tsx` is not in PATH in this environment. Always use the start script or the direct node command:
```bash
cd /wsl.localhost/Ubuntu/home/unional/nanoclaw-sandbox-5865
node node_modules/tsx/dist/cli.mjs src/index.ts > /tmp/nanoclaw-dev.log 2>&1 &
```

**`better-sqlite3` bindings missing** — The virtiofs filesystem does not support `symlink` syscall needed by node-gyp. Download the prebuilt binary instead:
```bash
npm install -g prebuild-install
cd /wsl.localhost/Ubuntu/home/unional/nanoclaw-sandbox-5865/node_modules/better-sqlite3
prebuild-install
```
The `start-nanoclaw.sh` script handles this automatically.

**Discord tokens not loaded** — Discord shows `no DISCORD_BOT_TOKEN configured` even though `.env` has the token. This means the process was NOT started from the project root. Always `cd` to the project root first; `src/env.ts` uses `process.cwd()` to find `.env`.

**`EADDRINUSE: 0.0.0.0:3001`** — another instance is already running. Stop it first:
```bash
pkill -f "tsx.*index\.ts" 2>/dev/null || true
pkill -f "node.*tsx/dist/cli" 2>/dev/null || true
sleep 2
# then re-run step 2
```

**WhatsApp exits immediately with "authentication required"** — Credentials are missing from `store/auth/`. Run `/setup` to re-authenticate WhatsApp. The process calls `process.exit(1)` when it needs a QR scan.

**Process exits immediately (other reasons)** — check the log:
```bash
cat /tmp/nanoclaw-dev.log
```
Common causes:
- `No channels connected` → credentials missing in `.env`
- Container runtime error → run `docker info` to verify Docker is up

**Only proxy-bootstrap lines in log, no pino output** — the process is alive but pino output is still buffering (this is normal on virtiofs and can take 60–90s). Wait longer before diagnosing.
