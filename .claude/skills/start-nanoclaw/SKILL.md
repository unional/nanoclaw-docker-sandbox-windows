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

## Steps

### 1. Check if already running

```bash
pgrep -f "tsx src/index" -a
```

If a process is found, NanoClaw is already up. Skip to step 3 to verify health.

### 2. Start NanoClaw

```bash
cd /wsl.localhost/Ubuntu/home/unional/nanoclaw-sandbox-5865
npm run dev > /tmp/nanoclaw-dev.log 2>&1 &
echo "Started PID: $!"
```

Wait ~30 seconds for Discord and WhatsApp to finish connecting.

### 3. Verify startup

```bash
sleep 30 && tail -50 /tmp/nanoclaw-dev.log
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
