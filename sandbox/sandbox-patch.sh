#!/bin/bash
# sandbox-patch.sh — Patches NanoClaw source for Docker Sandbox proxy/DinD compatibility.
# Idempotent: safe to run multiple times. Run from the NanoClaw project root.
#
# Patches applied:
#   1. Dockerfile: npm strict-ssl + proxy ARGs
#   2. container/build.sh: proxy build args
#   3. container-runner.ts: forward proxy env vars to agent containers
#   4. container-runner.ts: replace /dev/null shadow mount with .env.empty
#   5. container-runner.ts: mount proxy CA cert into agent containers
#   6. setup/container.ts: proxy build args
#   7. telegram.ts: proxy agent for grammy (if skill applied)
#   8. whatsapp.ts + whatsapp-auth.ts: proxy agent for Baileys (if skill applied)

set -e

# Resolve project root (script may live in sandbox/ or be copied to workspace root)
if [ -f "package.json" ]; then
  PROJECT_ROOT="$(pwd)"
elif [ -f "../package.json" ]; then
  PROJECT_ROOT="$(cd .. && pwd)"
else
  echo "ERROR: Run from NanoClaw project root or sandbox/ directory"
  exit 1
fi
cd "$PROJECT_ROOT"

APPLIED=0
SKIPPED=0

applied() { APPLIED=$((APPLIED + 1)); echo "  [ok] $1"; }
skipped() { SKIPPED=$((SKIPPED + 1)); echo "  [--] $1 (already applied)"; }
missing() { echo "  [..] $1 (file not found, skipping)"; }

echo "=== NanoClaw Sandbox Patches ==="
echo "Project root: $PROJECT_ROOT"
echo ""

# ---- Patch 1: Dockerfile npm strict-ssl + proxy ARGs ----
echo "[1/8] Dockerfile: npm strict-ssl + proxy ARGs"
if [ -f container/Dockerfile ]; then
  if grep -q "strict-ssl" container/Dockerfile; then
    skipped "Dockerfile strict-ssl"
  else
    sed -i '1,/^RUN npm install -g/{
      /^RUN npm install -g/i\
ARG http_proxy\
ARG https_proxy\
RUN npm config set strict-ssl false\

    }' container/Dockerfile
    applied "Dockerfile strict-ssl + proxy ARGs"
  fi
else
  missing "container/Dockerfile"
fi

# ---- Patch 2: container/build.sh proxy build args ----
echo "[2/8] container/build.sh: proxy build args"
if [ -f container/build.sh ]; then
  if grep -q "build-arg" container/build.sh; then
    skipped "build.sh proxy args"
  else
    sed -i '/\${CONTAINER_RUNTIME} build/i\
# Sandbox: forward proxy env vars to docker build\
BUILD_ARGS=""\
[ -n "$http_proxy" ] && BUILD_ARGS="$BUILD_ARGS --build-arg http_proxy=$http_proxy"\
[ -n "$https_proxy" ] && BUILD_ARGS="$BUILD_ARGS --build-arg https_proxy=$https_proxy"' container/build.sh
    sed -i 's|\${CONTAINER_RUNTIME} build -t|${CONTAINER_RUNTIME} build ${BUILD_ARGS} -t|' container/build.sh
    applied "build.sh proxy args"
  fi
else
  missing "container/build.sh"
fi

# ---- Patches 3-6: TypeScript patches via Node.js for reliability ----
echo "[3/8] container-runner.ts: forward proxy env vars"
echo "[4/8] container-runner.ts: replace /dev/null with .env.empty"
echo "[5/8] container-runner.ts: mount proxy CA cert"
echo "[6/8] setup/container.ts: proxy build args"

node --input-type=module << 'NODESCRIPT'
import fs from "fs";
import path from "path";

let applied = 0;
let skipped = 0;

function patchFile(filePath, patches) {
  if (!fs.existsSync(filePath)) {
    console.log(`  [..] ${filePath} not found, skipping`);
    return;
  }
  let content = fs.readFileSync(filePath, "utf8");
  let fileApplied = 0;

  for (const p of patches) {
    if (content.includes(p.marker)) {
      console.log(`  [--] ${filePath}: ${p.name} (already applied)`);
      skipped++;
      continue;
    }
    if (p.insertAfter) {
      const idx = content.indexOf(p.insertAfter);
      if (idx === -1) {
        console.log(`  [!!] ${filePath}: anchor not found for ${p.name}`);
        continue;
      }
      const lineEnd = content.indexOf("\n", idx);
      content = content.slice(0, lineEnd + 1) + p.code + "\n" + content.slice(lineEnd + 1);
      fileApplied++;
      applied++;
    }
    if (p.insertBefore) {
      const idx = content.indexOf(p.insertBefore);
      if (idx === -1) {
        console.log(`  [!!] ${filePath}: anchor not found for ${p.name}`);
        continue;
      }
      content = content.slice(0, idx) + p.code + "\n" + content.slice(idx);
      fileApplied++;
      applied++;
    }
    if (p.replace) {
      if (!content.includes(p.replace.from)) {
        console.log(`  [!!] ${filePath}: replace target not found for ${p.name}`);
        continue;
      }
      content = content.replace(p.replace.from, p.replace.to);
      fileApplied++;
      applied++;
    }
  }

  if (fileApplied > 0) {
    fs.writeFileSync(filePath, content);
    console.log(`  [ok] ${filePath}: ${fileApplied} patch(es) applied`);
  }
}

// Patch 3: Forward proxy env vars to agent containers
// Patch 4: Replace /dev/null with .env.empty
// Patch 5: Mount proxy CA cert
patchFile("src/container-runner.ts", [
  {
    name: "proxy-env",
    marker: "SANDBOX_PATCH_PROXY_ENV",
    insertAfter: "args.push('-e', `TZ=${TIMEZONE}`);",
    code: `
  // SANDBOX_PATCH_PROXY_ENV: forward proxy vars for sandbox environments
  for (const proxyVar of ['HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'NO_PROXY', 'no_proxy']) {
    if (process.env[proxyVar]) {
      args.push('-e', \`\${proxyVar}=\${process.env[proxyVar]}\`);
    }
  }
  if (process.env.SSL_CERT_FILE) {
    args.push('-e', 'SSL_CERT_FILE=/workspace/proxy-ca.crt');
    args.push('-e', 'REQUESTS_CA_BUNDLE=/workspace/proxy-ca.crt');
    args.push('-e', 'NODE_EXTRA_CA_CERTS=/workspace/proxy-ca.crt');
  }`,
  },
  {
    name: "env-empty",
    marker: "SANDBOX_PATCH_ENV_EMPTY",
    replace: {
      from: "hostPath: '/dev/null',",
      to: "hostPath: path.join(projectRoot, '.env.empty'), // SANDBOX_PATCH_ENV_EMPTY: DinD rejects /dev/null mounts",
    },
  },
  {
    name: "ca-cert",
    marker: "SANDBOX_PATCH_CA_CERT",
    insertBefore: "    // Shadow .env so the agent cannot read secrets",
    code: `    // SANDBOX_PATCH_CA_CERT: mount proxy CA certificate for sandbox environments
    const caCertPath = path.join(projectRoot, 'proxy-ca.crt');
    if (fs.existsSync(caCertPath)) {
      mounts.push({
        hostPath: caCertPath,
        containerPath: '/workspace/proxy-ca.crt',
        readonly: true,
      });
    }
`,
  },
]);

// Patch 6: setup/container.ts build args
patchFile("setup/container.ts", [
  {
    name: "build-args",
    marker: "SANDBOX_PATCH_BUILD_ARGS",
    replace: {
      from: "execSync(`${buildCmd} -t ${image} .`,",
      to: `// SANDBOX_PATCH_BUILD_ARGS: pass proxy args for sandbox builds
    const proxyBuildArgs: string[] = [];
    if (process.env.http_proxy) proxyBuildArgs.push('--build-arg', \`http_proxy=\${process.env.http_proxy}\`);
    if (process.env.https_proxy) proxyBuildArgs.push('--build-arg', \`https_proxy=\${process.env.https_proxy}\`);
    execSync(\`\${buildCmd} \${proxyBuildArgs.join(' ')} -t \${image} .\`,`,
    },
  },
]);

// Create .env.empty if it doesn't exist
if (!fs.existsSync(".env.empty")) {
  fs.writeFileSync(".env.empty", "");
  console.log("  [ok] Created .env.empty");
}

// Copy proxy CA cert to project root if available in sandbox
const caCertSrc = "/usr/local/share/ca-certificates/proxy-ca.crt";
if (fs.existsSync(caCertSrc) && !fs.existsSync("proxy-ca.crt")) {
  fs.copyFileSync(caCertSrc, "proxy-ca.crt");
  console.log("  [ok] Copied proxy-ca.crt to project root");
}

// Write counts to temp file for bash to pick up
fs.writeFileSync("/tmp/.sandbox-patch-counts", `${applied} ${skipped}`);
NODESCRIPT

# Read counts from Node.js
if [ -f /tmp/.sandbox-patch-counts ]; then
  read NODE_APPLIED NODE_SKIPPED < /tmp/.sandbox-patch-counts
  APPLIED=$((APPLIED + NODE_APPLIED))
  SKIPPED=$((SKIPPED + NODE_SKIPPED))
  rm -f /tmp/.sandbox-patch-counts
fi

# ---- Patch 7: Telegram proxy agent (conditional) ----
echo "[7/8] telegram.ts: proxy agent for grammy"
if [ -f src/channels/telegram.ts ]; then
  node --input-type=module << 'NODESCRIPT'
import fs from "fs";

const filePath = "src/channels/telegram.ts";
let content = fs.readFileSync(filePath, "utf8");

if (content.includes("SANDBOX_PATCH_TELEGRAM_PROXY")) {
  console.log("  [--] telegram.ts: proxy agent (already applied)");
  fs.writeFileSync("/tmp/.sandbox-patch-counts", "0 1");
  process.exit(0);
}

let applied = 0;

// Add HttpsProxyAgent import
if (!content.includes("HttpsProxyAgent")) {
  content = content.replace(
    "import { Bot } from 'grammy';",
    `import { Bot } from 'grammy';
import { HttpsProxyAgent } from 'https-proxy-agent'; // SANDBOX_PATCH_TELEGRAM_PROXY`
  );
  applied++;
}

// Add proxy agent to Bot constructor
content = content.replace(
  "this.bot = new Bot(this.botToken);",
  `// SANDBOX_PATCH_TELEGRAM_PROXY: route grammy through sandbox proxy
    const proxyUrl = process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY || process.env.http_proxy;
    const botConfig = proxyUrl
      ? { client: { baseFetchConfig: { agent: new HttpsProxyAgent(proxyUrl) } } }
      : undefined;
    this.bot = new Bot(this.botToken, botConfig);`
);
applied++;

fs.writeFileSync(filePath, content);
console.log(`  [ok] telegram.ts: ${applied} patch(es) applied`);
fs.writeFileSync("/tmp/.sandbox-patch-counts", `${applied} 0`);
NODESCRIPT
  if [ -f /tmp/.sandbox-patch-counts ]; then
    read NODE_APPLIED NODE_SKIPPED < /tmp/.sandbox-patch-counts
    APPLIED=$((APPLIED + NODE_APPLIED))
    SKIPPED=$((SKIPPED + NODE_SKIPPED))
    rm -f /tmp/.sandbox-patch-counts
  fi
else
  missing "src/channels/telegram.ts"
fi

# ---- Patch 8: WhatsApp proxy agent (conditional) ----
echo "[8/8] whatsapp.ts + whatsapp-auth.ts: proxy agent for Baileys"

patch_whatsapp_file() {
  local FILE="$1"
  if [ ! -f "$FILE" ]; then
    missing "$FILE"
    return
  fi

  node --input-type=module << NODESCRIPT
import fs from "fs";

const filePath = "$FILE";
let content = fs.readFileSync(filePath, "utf8");

if (content.includes("SANDBOX_PATCH_WA_PROXY")) {
  console.log("  [--] $FILE: proxy agent (already applied)");
  fs.writeFileSync("/tmp/.sandbox-patch-counts", "0 1");
  process.exit(0);
}

let applied = 0;

// Add HttpsProxyAgent import after the baileys import block
if (!content.includes("HttpsProxyAgent")) {
  // Find the last import from @whiskeysockets/baileys
  const baileyImportEnd = content.lastIndexOf("from '@whiskeysockets/baileys';");
  if (baileyImportEnd !== -1) {
    const lineEnd = content.indexOf("\\n", baileyImportEnd);
    content = content.slice(0, lineEnd + 1) +
      "import { HttpsProxyAgent } from 'https-proxy-agent'; // SANDBOX_PATCH_WA_PROXY\\n" +
      content.slice(lineEnd + 1);
    applied++;
  }
}

// Add proxy agent helper function before the first class/const/function after imports
// Insert a fetchWaVersionViaProxy function
if (!content.includes("fetchWaVersionViaProxy")) {
  const insertPoint = content.indexOf("\\nconst ");
  if (insertPoint === -1) {
    // Try before class declaration
    const classPoint = content.indexOf("\\nexport class ");
    if (classPoint !== -1) {
      content = content.slice(0, classPoint) + \`
// SANDBOX_PATCH_WA_PROXY: fetch WhatsApp version through proxy
async function fetchWaVersionViaProxy(): Promise<[number, number, number] | undefined> {
  const proxyUrl = process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY || process.env.http_proxy;
  if (!proxyUrl) return undefined;
  try {
    const agent = new HttpsProxyAgent(proxyUrl);
    const res = await fetch('https://web.whatsapp.com/sw.js', { agent } as any);
    const text = await res.text();
    const match = text.match(/client_revision\\\\s*[:=]\\\\s*(\\\\d+)/);
    if (match) {
      return [2, 3000, parseInt(match[1], 10)];
    }
  } catch {}
  return undefined;
}
\` + content.slice(classPoint);
      applied++;
    }
  } else {
    content = content.slice(0, insertPoint) + \`
// SANDBOX_PATCH_WA_PROXY: fetch WhatsApp version through proxy
async function fetchWaVersionViaProxy(): Promise<[number, number, number] | undefined> {
  const proxyUrl = process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY || process.env.http_proxy;
  if (!proxyUrl) return undefined;
  try {
    const agent = new HttpsProxyAgent(proxyUrl);
    const res = await fetch('https://web.whatsapp.com/sw.js', { agent } as any);
    const text = await res.text();
    const match = text.match(/client_revision\\\\s*[:=]\\\\s*(\\\\d+)/);
    if (match) {
      return [2, 3000, parseInt(match[1], 10)];
    }
  } catch {}
  return undefined;
}
\` + content.slice(insertPoint);
    applied++;
  }
}

// Patch fetchLatestWaWebVersion to use proxy version first
content = content.replace(
  /const \{ version \} = await fetchLatestWaWebVersion\(\{[^}]*\}\)\.catch\(/,
  \`// SANDBOX_PATCH_WA_PROXY: try proxy-aware version fetch first
    const proxyVersion = await fetchWaVersionViaProxy();
    const { version } = proxyVersion
      ? { version: proxyVersion }
      : await fetchLatestWaWebVersion({}).catch(\`
);
if (content.includes("SANDBOX_PATCH_WA_PROXY: try proxy")) applied++;

// Add proxy agent to makeWASocket options
content = content.replace(
  /makeWASocket\(\{(\s+)version,/,
  \`makeWASocket({
\$1// SANDBOX_PATCH_WA_PROXY: route WebSocket through proxy
\$1agent: (() => { const p = process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY || process.env.http_proxy; return p ? new HttpsProxyAgent(p) : undefined; })(),
\$1fetchAgent: (() => { const p = process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY || process.env.http_proxy; return p ? new HttpsProxyAgent(p) : undefined; })(),
\$1version,\`
);
if (content.includes("SANDBOX_PATCH_WA_PROXY: route WebSocket")) applied++;

fs.writeFileSync(filePath, content);
console.log("  [ok] $FILE: " + applied + " patch(es) applied");
fs.writeFileSync("/tmp/.sandbox-patch-counts", applied + " 0");
NODESCRIPT
  if [ -f /tmp/.sandbox-patch-counts ]; then
    read NODE_APPLIED NODE_SKIPPED < /tmp/.sandbox-patch-counts
    APPLIED=$((APPLIED + NODE_APPLIED))
    SKIPPED=$((SKIPPED + NODE_SKIPPED))
    rm -f /tmp/.sandbox-patch-counts
  fi
}

patch_whatsapp_file "src/channels/whatsapp.ts"
patch_whatsapp_file "src/whatsapp-auth.ts"

echo ""
echo "=== Done: $APPLIED applied, $SKIPPED already applied ==="
