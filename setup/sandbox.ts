/**
 * Step: sandbox — Create and configure a Docker AI Sandbox for NanoClaw.
 * Handles sandbox lifecycle, proxy bypass, and initialization.
 *
 * Usage:
 *   npx tsx setup/index.ts --step sandbox -- --action preflight
 *   npx tsx setup/index.ts --step sandbox -- --action create [--template <image>] [--workspace <path>]
 *   npx tsx setup/index.ts --step sandbox -- --action proxy-bypass --name <sandbox-name>
 *   npx tsx setup/index.ts --step sandbox -- --action init --name <sandbox-name>
 *   npx tsx setup/index.ts --step sandbox -- --action exec --name <sandbox-name> --cmd <command>
 *   npx tsx setup/index.ts --step sandbox -- --action status --name <sandbox-name>
 */
import { execSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';

import { logger } from '../src/logger.js';
import { commandExists } from './platform.js';
import { emitStatus } from './status.js';

interface SandboxArgs {
  action: string;
  name: string;
  template: string;
  workspace: string;
  cmd: string;
}

function parseArgs(args: string[]): SandboxArgs {
  const result: SandboxArgs = {
    action: '',
    name: '',
    template: '',
    workspace: path.join(os.homedir(), 'nanoclaw-workspace'),
    cmd: '',
  };

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--action':
        result.action = args[++i] || '';
        break;
      case '--name':
        result.name = args[++i] || '';
        break;
      case '--template':
        result.template = args[++i] || '';
        break;
      case '--workspace':
        result.workspace = args[++i] || '';
        break;
      case '--cmd':
        result.cmd = args.slice(i + 1).join(' ');
        i = args.length; // consume rest
        break;
    }
  }

  return result;
}

/** Derive sandbox name from workspace path (matches Docker convention). */
function deriveSandboxName(workspace: string): string {
  const base = path.basename(workspace);
  return `shell-${base}`;
}

export async function run(args: string[]): Promise<void> {
  const parsed = parseArgs(args);

  switch (parsed.action) {
    case 'preflight':
      return preflight();
    case 'create':
      return create(parsed);
    case 'proxy-bypass':
      return proxyBypass(parsed);
    case 'init':
      return init(parsed);
    case 'exec':
      return sandboxExec(parsed);
    case 'status':
      return status(parsed);
    default:
      emitStatus('SANDBOX', {
        STATUS: 'failed',
        ERROR: 'missing_action',
        USAGE:
          'preflight | create | proxy-bypass | init | exec | status',
      });
      process.exit(4);
  }
}

/** Check Docker Desktop and sandbox CLI prerequisites. */
async function preflight(): Promise<void> {
  logger.info('Checking Docker Sandbox prerequisites');

  const hasDocker = commandExists('docker');

  let sandboxVersion = '';
  let sandboxAvailable = false;
  if (hasDocker) {
    try {
      sandboxVersion = execSync('docker sandbox version', {
        encoding: 'utf-8',
        stdio: ['pipe', 'pipe', 'pipe'],
      }).trim();
      sandboxAvailable = true;
    } catch {
      // docker sandbox not available
    }
  }

  // Check Docker Desktop version
  let dockerVersion = '';
  if (hasDocker) {
    try {
      dockerVersion = execSync('docker version --format "{{.Client.Version}}"', {
        encoding: 'utf-8',
        stdio: ['pipe', 'pipe', 'pipe'],
      }).trim();
    } catch {
      // couldn't get version
    }
  }

  // List existing sandboxes
  let existingSandboxes: string[] = [];
  if (sandboxAvailable) {
    try {
      const ls = execSync('docker sandbox ls --format "{{.Name}}"', {
        encoding: 'utf-8',
        stdio: ['pipe', 'pipe', 'pipe'],
      }).trim();
      existingSandboxes = ls ? ls.split('\n').filter(Boolean) : [];
    } catch {
      // couldn't list
    }
  }

  emitStatus('SANDBOX_PREFLIGHT', {
    DOCKER_INSTALLED: hasDocker,
    DOCKER_VERSION: dockerVersion,
    SANDBOX_AVAILABLE: sandboxAvailable,
    SANDBOX_VERSION: sandboxVersion,
    EXISTING_SANDBOXES: existingSandboxes.join(',') || 'none',
    STATUS: hasDocker && sandboxAvailable ? 'success' : 'failed',
    ERROR: !hasDocker
      ? 'docker_not_found'
      : !sandboxAvailable
        ? 'sandbox_not_available'
        : '',
  });

  if (!hasDocker || !sandboxAvailable) process.exit(1);
}

/** Create workspace directory and Docker Sandbox. */
async function create(parsed: SandboxArgs): Promise<void> {
  const workspace = parsed.workspace;
  const name = parsed.name || deriveSandboxName(workspace);
  const template = parsed.template;

  logger.info({ workspace, name, template }, 'Creating Docker Sandbox');

  // Create workspace directory
  fs.mkdirSync(workspace, { recursive: true });

  // Copy sandbox scripts into workspace so they're accessible inside
  const projectRoot = process.cwd();
  const sandboxDir = path.join(projectRoot, 'sandbox');
  if (fs.existsSync(sandboxDir)) {
    for (const file of fs.readdirSync(sandboxDir)) {
      const src = path.join(sandboxDir, file);
      const dst = path.join(workspace, file);
      if (fs.statSync(src).isFile()) {
        fs.copyFileSync(src, dst);
      }
    }
    logger.info('Copied sandbox scripts to workspace');
  }

  // Check if sandbox already exists
  let alreadyExists = false;
  try {
    const ls = execSync('docker sandbox ls --format "{{.Name}}"', {
      encoding: 'utf-8',
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
    alreadyExists = ls.split('\n').includes(name);
  } catch {
    // couldn't list
  }

  if (alreadyExists) {
    emitStatus('SANDBOX_CREATE', {
      NAME: name,
      WORKSPACE: workspace,
      STATUS: 'exists',
      ERROR: 'sandbox_already_exists',
    });
    return;
  }

  // Create sandbox with network bypass plugin
  const templateArgs = template ? `-t ${template} ` : '';
  const pluginDir = path.join(workspace, 'nanoclaw', 'sandbox', 'docker-plugin');
  const pluginArgs = fs.existsSync(pluginDir) ? `--plugin ${JSON.stringify(pluginDir)} ` : '';
  const cmd = `docker sandbox create ${templateArgs}${pluginArgs}shell ${JSON.stringify(workspace)}`;

  try {
    execSync(cmd, {
      encoding: 'utf-8',
      stdio: ['pipe', 'pipe', 'pipe'],
      timeout: 600000, // 10 min — image pulls can be slow
    });
    logger.info({ name }, 'Sandbox created');
  } catch (err) {
    const message = err instanceof Error ? (err as any).stderr || err.message : String(err);
    logger.error({ err }, 'Failed to create sandbox');
    emitStatus('SANDBOX_CREATE', {
      NAME: name,
      WORKSPACE: workspace,
      TEMPLATE: template,
      STATUS: 'failed',
      ERROR: message,
    });
    process.exit(1);
  }

  emitStatus('SANDBOX_CREATE', {
    NAME: name,
    WORKSPACE: workspace,
    TEMPLATE: template || 'none',
    STATUS: 'success',
  });
}

/** Configure proxy bypass for WhatsApp hosts (MITM inspection skip). */
async function proxyBypass(parsed: SandboxArgs): Promise<void> {
  const name = parsed.name;
  if (!name) {
    emitStatus('SANDBOX_PROXY', {
      STATUS: 'failed',
      ERROR: 'missing_sandbox_name',
    });
    process.exit(4);
  }

  logger.info({ name }, 'Configuring proxy bypass for WhatsApp');

  const bypasses = [
    'web.whatsapp.com',
    '*.whatsapp.com',
    '*.whatsapp.net',
  ];

  const bypassArgs = bypasses
    .map((h) => `--bypass-host ${JSON.stringify(h)}`)
    .join(' ');

  try {
    execSync(`docker sandbox network proxy ${name} ${bypassArgs}`, {
      encoding: 'utf-8',
      stdio: ['pipe', 'pipe', 'pipe'],
      timeout: 30000,
    });
    logger.info('Proxy bypass configured');
  } catch (err) {
    const message = err instanceof Error ? (err as any).stderr || err.message : String(err);
    logger.error({ err }, 'Failed to configure proxy bypass');
    emitStatus('SANDBOX_PROXY', {
      NAME: name,
      STATUS: 'failed',
      ERROR: message,
    });
    process.exit(1);
  }

  emitStatus('SANDBOX_PROXY', {
    NAME: name,
    BYPASS_HOSTS: bypasses.join(','),
    STATUS: 'success',
  });
}

/** Run the NanoClaw initialization inside the sandbox. */
async function init(parsed: SandboxArgs): Promise<void> {
  const name = parsed.name;
  if (!name) {
    emitStatus('SANDBOX_INIT', {
      STATUS: 'failed',
      ERROR: 'missing_sandbox_name',
    });
    process.exit(4);
  }

  logger.info({ name }, 'Initializing NanoClaw inside sandbox');

  // Check if already initialized
  try {
    const check = execSync(
      `docker sandbox exec ${name} bash -c "test -f /home/agent/.nanoclaw-initialized && echo YES || echo NO"`,
      { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] },
    ).trim();

    if (check === 'YES') {
      emitStatus('SANDBOX_INIT', {
        NAME: name,
        STATUS: 'already_initialized',
      });
      return;
    }
  } catch {
    // exec failed — sandbox might not be running
  }

  // Check for init.sh in mounted workspace
  let hasInitScript = false;
  try {
    const check = execSync(
      `docker sandbox exec ${name} bash -c "WORKSPACE=\\$(df -h | grep virtiofs | head -1 | awk '{print \\$NF}'); test -f \\$WORKSPACE/nanoclaw/sandbox/init.sh && echo YES || echo NO"`,
      { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] },
    ).trim();
    hasInitScript = check === 'YES';
  } catch {
    // exec failed
  }

  emitStatus('SANDBOX_INIT', {
    NAME: name,
    HAS_INIT_SCRIPT: hasInitScript,
    STATUS: 'ready',
  });
}

/** Execute a command inside the sandbox and return output. */
async function sandboxExec(parsed: SandboxArgs): Promise<void> {
  const { name, cmd } = parsed;
  if (!name || !cmd) {
    emitStatus('SANDBOX_EXEC', {
      STATUS: 'failed',
      ERROR: !name ? 'missing_sandbox_name' : 'missing_cmd',
    });
    process.exit(4);
  }

  logger.info({ name, cmd }, 'Executing command in sandbox');

  try {
    const output = execSync(
      `docker sandbox exec ${name} bash -c ${JSON.stringify(cmd)}`,
      {
        encoding: 'utf-8',
        stdio: ['pipe', 'pipe', 'pipe'],
        timeout: 300000,
      },
    );

    emitStatus('SANDBOX_EXEC', {
      NAME: name,
      CMD: cmd,
      OUTPUT: output.trim().slice(0, 2000),
      STATUS: 'success',
    });
  } catch (err) {
    const message = err instanceof Error ? (err as any).stderr || err.message : String(err);
    emitStatus('SANDBOX_EXEC', {
      NAME: name,
      CMD: cmd,
      STATUS: 'failed',
      ERROR: message.slice(0, 2000),
    });
    process.exit(1);
  }
}

/** Check sandbox status and NanoClaw state inside it. */
async function status(parsed: SandboxArgs): Promise<void> {
  const name = parsed.name;
  if (!name) {
    emitStatus('SANDBOX_STATUS', {
      STATUS: 'failed',
      ERROR: 'missing_sandbox_name',
    });
    process.exit(4);
  }

  // Check sandbox exists and is running
  let sandboxRunning = false;
  let sandboxStatus = 'not_found';
  try {
    const ls = execSync(
      `docker sandbox ls --format "{{.Name}}:{{.Status}}"`,
      { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] },
    ).trim();
    for (const line of ls.split('\n')) {
      const [n, s] = line.split(':');
      if (n === name) {
        sandboxStatus = s || 'unknown';
        sandboxRunning = s?.toLowerCase().includes('running') || false;
        break;
      }
    }
  } catch {
    // couldn't list
  }

  // Check NanoClaw state inside sandbox (only if running)
  let initialized = false;
  let nanoclaw_found = false;
  let node_running = false;
  if (sandboxRunning) {
    try {
      const check = execSync(
        `docker sandbox exec ${name} bash -c "echo INIT=\$(test -f /home/agent/.nanoclaw-initialized && echo true || echo false); WORKSPACE=\$(cat /home/agent/.nanoclaw-workspace 2>/dev/null || echo ''); test -d \\"\\$WORKSPACE/nanoclaw\\" && echo NC=true || echo NC=false; pgrep -f 'dist/index.js' >/dev/null && echo NODE=true || echo NODE=false"`,
        { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] },
      ).trim();
      initialized = check.includes('INIT=true');
      nanoclaw_found = check.includes('NC=true');
      node_running = check.includes('NODE=true');
    } catch {
      // exec failed
    }
  }

  emitStatus('SANDBOX_STATUS', {
    NAME: name,
    SANDBOX_STATUS: sandboxStatus,
    SANDBOX_RUNNING: sandboxRunning,
    NANOCLAW_INITIALIZED: initialized,
    NANOCLAW_FOUND: nanoclaw_found,
    NANOCLAW_RUNNING: node_running,
    STATUS: 'success',
  });
}
