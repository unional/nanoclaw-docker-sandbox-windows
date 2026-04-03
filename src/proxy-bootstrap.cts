/**
 * Global proxy bootstrap for Docker Sandbox environments.
 *
 * THIS IS A CJS MODULE (.cts) — it runs SYNCHRONOUSLY during the ESM LINK
 * phase, before @discordjs/ws captures ws.WebSocket as a module-level
 * variable (line 602 of @discordjs/ws/dist/index.js). This is essential for
 * the WebSocket proxy patch (Layer 3) to work.
 *
 * Why CJS instead of the previous ESM .ts with top-level await:
 *   - https-proxy-agent@8 is ESM-only; dynamic import() of ESM packages
 *     deadlocks when called from a top-level-await ESM module that is part
 *     of a larger module graph being linked (discord.ts statically imports
 *     undici and discord.js which both get loaded during the same ESM link
 *     phase, causing the ESM module loader to deadlock).
 *   - A CJS module imported first in index.ts runs synchronously before any
 *     other module in the graph, so the ws patch takes effect before
 *     @discordjs/ws reads import_ws.WebSocket at its module level.
 *
 * Layers patched:
 *   1. https.globalAgent → tunnel-agent httpsOverHttp (covers https.request,
 *      node-fetch, axios, and any library that respects https.globalAgent)
 *   2. undici: SKIPPED — discord.ts statically imports undici; loading undici
 *      here would cause issues. Discord REST is already proxied via
 *      Client({ rest: { agent } }).
 *   3. ws.WebSocket → ProxiedWebSocket injects agent on every new connection
 *      that doesn't already have one. This covers discord.js gateway.
 *      WhatsApp (Baileys) passes its own agent explicitly, so the
 *      `options.agent` guard avoids double-wrapping those connections.
 *
 * tunnel-agent (transitive dep via better-sqlite3 → prebuild-install) is used
 * because https-proxy-agent@8 is ESM-only and cannot be require()d from CJS.
 */

// Use require() directly (not import * as) to get the real module object.
// TypeScript's `import * as https` compiles to __importStar(require('https')),
// which wraps the module in a frozen namespace object where globalAgent is
// non-configurable, causing Object.defineProperty to throw.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const https = require('https') as typeof import('https');

const proxyUrl =
  process.env.HTTPS_PROXY ||
  process.env.https_proxy ||
  process.env.HTTP_PROXY ||
  process.env.http_proxy;

if (proxyUrl) {
  const parsedProxy = new URL(proxyUrl);
  const proxyOpts = {
    proxy: { host: parsedProxy.hostname, port: parseInt(parsedProxy.port) || 3128 },
  };

  // Layer 1: Set https.globalAgent using tunnel-agent
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const tunnel = require('tunnel-agent') as any;
    const agent = tunnel.httpsOverHttp(proxyOpts);
    // tunnel-agent doesn't set .protocol; Node's ClientRequest checks
    // options.protocol || agent.protocol and throws if it ends up undefined.
    agent.protocol = 'https:';
    // https.globalAgent is read-only in Node.js v20, use defineProperty
    Object.defineProperty(https, 'globalAgent', { value: agent, writable: true, configurable: true });
    console.log(`[proxy-bootstrap] Layer 1: https.globalAgent → tunnel httpsOverHttp (${proxyUrl})`);
  } catch (err: any) {
    console.warn('[proxy-bootstrap] Layer 1 failed:', err?.message);
  }

  // Layer 3: Patch ws.WebSocket synchronously (CJS ensures this runs before
  // @discordjs/ws captures ws.WebSocket at its module level)
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const tunnel = require('tunnel-agent') as any;
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const wsModule = require('ws') as any;
    const wsAgent = tunnel.httpsOverHttp(proxyOpts);
    const OrigWS = wsModule.WebSocket as new (...args: any[]) => any;

    class ProxiedWebSocket extends OrigWS {
      constructor(url: string, protocols?: any, options: any = {}) {
        super(url, protocols, options.agent ? options : { ...options, agent: wsAgent });
      }
    }

    wsModule.WebSocket = ProxiedWebSocket;
    console.log('[proxy-bootstrap] Layer 3: ws.WebSocket patched with tunnel agent');
  } catch (err: any) {
    console.warn('[proxy-bootstrap] Layer 3 failed:', err?.message);
  }
}
