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
#
# Telegram and WhatsApp networking is handled by the Docker Sandbox plugin
# (docker-plugin/network.json bypassDomains) — no code patches needed.

set -e

# virtiofs-safe sed -i replacement (sed -i fails on virtiofs shared mounts)
sedi() {
  local file="${@: -1}"
  local args=("${@:1:$#-1}")
  sed "${args[@]}" "$file" > /tmp/_sedi_tmp && mv /tmp/_sedi_tmp "$file"
}

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
echo "[1/6] Dockerfile: npm strict-ssl + proxy ARGs"
if [ -f container/Dockerfile ]; then
  if grep -q "strict-ssl" container/Dockerfile; then
    skipped "Dockerfile strict-ssl"
  else
    sedi '1,/^RUN npm install -g/{
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
echo "[2/6] container/build.sh: proxy build args"
if [ -f container/build.sh ]; then
  if grep -q "build-arg" container/build.sh; then
    skipped "build.sh proxy args"
  else
    sedi '/\${CONTAINER_RUNTIME} build/i\
# Sandbox: forward proxy env vars to docker build\
BUILD_ARGS=""\
[ -n "$http_proxy" ] && BUILD_ARGS="$BUILD_ARGS --build-arg http_proxy=$http_proxy"\
[ -n "$https_proxy" ] && BUILD_ARGS="$BUILD_ARGS --build-arg https_proxy=$https_proxy"' container/build.sh
    sedi 's|\${CONTAINER_RUNTIME} build -t|${CONTAINER_RUNTIME} build ${BUILD_ARGS} -t|' container/build.sh
    applied "build.sh proxy args"
  fi
else
  missing "container/build.sh"
fi

# ---- Patches 3-6: TypeScript patches via Node.js for reliability ----
echo "[3/6] container-runner.ts: forward proxy env vars"
echo "[4/6] container-runner.ts: replace /dev/null with .env.empty"
echo "[5/6] container-runner.ts: mount proxy CA cert"
echo "[6/6] setup/container.ts: proxy build args"

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

echo ""
echo "=== Done: $APPLIED applied, $SKIPPED already applied ==="
