/**
 * Global proxy bootstrap for Docker Sandbox environments.
 *
 * Import this module early in the process (before any HTTP calls) to route
 * ALL outbound requests through the sandbox MITM proxy. This eliminates the
 * need for per-library proxy configuration in most cases.
 *
 * Two layers are patched:
 *   1. https.globalAgent → HttpsProxyAgent  (covers node-fetch, axios, etc.)
 *      Libraries that create their own agent (e.g. Grammy) must be configured
 *      to use https.globalAgent instead — see telegram.ts baseFetchConfig.
 *   2. undici global dispatcher → ProxyAgent (covers Node's built-in fetch)
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

  // Layer 2: Node's built-in fetch (undici)
  try {
    const mod = await (Function(
      'return import("undici")',
    )() as Promise<any>);
    const opts: any = { uri: proxyUrl };
    if (ca) opts.requestTls = { ca };
    mod.setGlobalDispatcher(new mod.ProxyAgent(opts));
    logger.info(
      { proxy: proxyUrl },
      'Global undici proxy dispatcher set (built-in fetch layer)',
    );
  } catch {
    // undici not available — non-sandbox or not installed
  }
}
