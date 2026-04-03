/**
 * Global proxy bootstrap for Docker Sandbox environments.
 *
 * Import this module early in the process (before any HTTP calls) to route
 * ALL outbound requests through the sandbox MITM proxy. This eliminates the
 * need for per-library proxy configuration in most cases.
 *
 * Three layers are patched:
 *   1. https.globalAgent → HttpsProxyAgent  (covers node-fetch, axios, etc.)
 *      Libraries that create their own agent (e.g. Grammy) must be configured
 *      to use https.globalAgent instead — see telegram.ts baseFetchConfig.
 *   2. undici global dispatcher → ProxyAgent (covers Node's built-in fetch)
 *   3. ws.WebSocket patched → injects HttpsProxyAgent into every WebSocket
 *      connection that doesn't already have an agent set. The ws package
 *      bypasses https.globalAgent (it uses tls.connect directly), so discord.js
 *      gateway WebSocket connections would otherwise fail in sandboxed networks.
 *      This must run before any module that imports discord.js/@discordjs/ws
 *      captures ws.WebSocket into a module-level variable.
 */
import fs from 'fs';
import https from 'https';

import { logger } from './logger.js';

const proxyUrl =
  process.env.HTTPS_PROXY ||
  process.env.https_proxy ||
  process.env.HTTP_PROXY ||
  process.env.http_proxy;

if (proxyUrl) {
  // Read sandbox MITM CA cert if available (needed for TLS through the proxy)
  const caPath = process.env.NODE_EXTRA_CA_CERTS;
  let ca: Buffer | undefined;
  if (caPath) {
    try {
      ca = fs.readFileSync(caPath);
    } catch {
      /* cert file not readable */
    }
  }

  // Layer 1: Set https.globalAgent to proxy agent.
  // Covers node-fetch, axios, and any library that doesn't override the agent.
  // Libraries like Grammy that create their own agent need to be configured
  // to use https.globalAgent explicitly (e.g. baseFetchConfig: { agent: https.globalAgent }).
  try {
    const mod = await (Function(
      'return import("https-proxy-agent")',
    )() as Promise<any>);
    https.globalAgent = new mod.HttpsProxyAgent(proxyUrl, ca ? { ca } : {});
    logger.info(
      { proxy: proxyUrl },
      'Global HTTPS proxy agent set (node-fetch layer)',
    );
  } catch {
    // https-proxy-agent not installed — non-sandbox environment
  }

  // Layer 2: Node's built-in fetch (undici global dispatcher)
  // SKIPPED: dynamic import('undici') deadlocks when discord.js also loads undici
  // concurrently during ESM module graph initialization. Discord REST calls are
  // already proxied via the explicit Client({ rest: { agent } }) configuration.
  // Any app-level fetch() calls that need proxying can use https.globalAgent
  // (layer 1) via a node-fetch/axios wrapper, or set up undici after startup.

  // Layer 3: Patch ws.WebSocket to inject the proxy agent.
  // The ws npm package (used by discord.js gateway) bypasses https.globalAgent
  // and calls tls.connect() directly, so setting https.globalAgent is not enough.
  // We patch ws.WebSocket here — before channels/discord.ts imports discord.js —
  // so that @discordjs/ws captures the patched class in its module-level variable.
  // WhatsApp (Baileys) already passes its own agent explicitly, so the
  // `if (!options.agent)` guard avoids double-wrapping those connections.
  try {
    const { createRequire } = await import('module');
    const req = createRequire(import.meta.url);
    const wsModule = req('ws') as any;
    const hpaMod = await (Function(
      'return import("https-proxy-agent")',
    )() as Promise<any>);
    const wsAgent = new hpaMod.HttpsProxyAgent(proxyUrl);
    const OrigWS = wsModule.WebSocket;
    class ProxiedWebSocket extends OrigWS {
      constructor(url: string, protocols?: any, options: any = {}) {
        super(url, protocols, options.agent ? options : { ...options, agent: wsAgent });
      }
    }
    wsModule.WebSocket = ProxiedWebSocket;
    logger.info(
      { proxy: proxyUrl },
      'ws.WebSocket patched with proxy agent (discord.js gateway layer)',
    );
  } catch {
    // ws not installed — non-sandbox or discord channel not added
  }
}
