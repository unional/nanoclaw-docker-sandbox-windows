---
name: start-nanoclaw
description: Start NanoClaw and verify all channels are connected. Use when NanoClaw is not running or after a restart. Handles WSL environment where systemctl is unavailable.
---

# Start NanoClaw

Start NanoClaw and confirm it is fully running with all channels connected.

## Environment Notes

- `systemctl` is not available in this WSL environment — do not try it.
- Always check for an existing instance before starting to avoid `EADDRINUSE: 0.0.0.0:3001`.
- Pino logger output is buffered; proxy-bootstrap messages (`[proxy-bootstrap] Layer 1/3`) appear first. Wait ~30s for full startup before checking logs.
- A background task reporting "exit code 0" does NOT mean the process died — the task wrapper exits while the NanoClaw process keeps running.
- NanoClaw may have been started as a background Claude task — its stdout will be a task output file, not `/tmp/nanoclaw-dev.log`. Always discover the actual log via the process file descriptor.

## Steps

### 1. Check if already running

```bash
pgrep -af "tsx src/index"
```

**If a process is found** — go to step 1b.
**If no process is found** — go to step 2.

### 1b. Health check (already running)

Find the actual log file and read recent output:

```bash
PID=$(pgrep -f "tsx src/index" | head -1)
LOG=$(readlink -f /proc/$PID/fd/1 2>/dev/null || echo "/tmp/nanoclaw-dev.log")
tail -30 "$LOG"
```

**Healthy** if: recent lines contain `INFO` entries (message processing, agent spawning, messages sent, etc.) and no fatal `ERROR` lines.

**Done — report status cleanly** (see Response Format below). Do not proceed to step 2.

**Unhealthy** if: only old lines, fatal errors, or the process is stuck. Restart: kill with `pkill -f "tsx src/index"`, then proceed to step 2.

### 2. Start NanoClaw

```bash
cd /wsl.localhost/Ubuntu/home/unional/nanoclaw-sandbox-5865
npm run dev > /tmp/nanoclaw-dev.log 2>&1 &
echo "Started PID: $!"
```

Wait ~30 seconds for Discord and WhatsApp to finish connecting.

### 3. Verify fresh startup

```bash
PID=$(pgrep -f "tsx src/index" | head -1)
LOG=$(readlink -f /proc/$PID/fd/1 2>/dev/null || echo "/tmp/nanoclaw-dev.log")
sleep 30 && tail -50 "$LOG"
```

Look for these success indicators:
- `Discord bot connected` — Discord is up
- `Connected to WhatsApp` — WhatsApp is up
- `NanoClaw running (trigger: @NanoClaw)` — message loop is active
- `Scheduler loop started` — scheduled tasks are active
- `IPC watcher started` — IPC is active

### 4. Confirm process is still alive

```bash
pgrep -f "tsx src/index" && echo "running" || echo "stopped"
```

## Response Format

Once health is confirmed, output a concise status line. Do not narrate investigation steps. Examples:

- "NanoClaw is running — Discord and WhatsApp connected."
- "NanoClaw started successfully — Discord and WhatsApp connected."
- "NanoClaw is running — Discord connected. WhatsApp reconnecting (last seen X min ago)."

List only channels that are visibly active in recent logs. Do not hedge or say "let me check...".

## Troubleshooting

**`EADDRINUSE: 0.0.0.0:3001`** — another instance is already running. Stop it first:
```bash
pkill -f "tsx src/index"
sleep 2
# then re-run step 2
```

**Process exits immediately** — check the log for fatal errors:
```bash
cat /tmp/nanoclaw-dev.log
```

Common causes:
- `No channels connected` → credentials missing in `.env`
- Container runtime error → run `docker info` to verify Docker is up

**Proxy bootstrap shows but no logger output** — the process is alive but pino output is still buffering. Wait longer (up to 45s on cold start).
