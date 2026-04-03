#!/usr/bin/env node
/**
 * generate-image CLI tool
 * Usage: generate-image "<prompt>" [output-path]
 *
 * In containers (ANTHROPIC_BASE_URL set): routes through the credential proxy,
 * which calls Pollinations.ai from the host (containers can't reach external
 * URLs directly in the sandbox).
 *
 * Standalone (no ANTHROPIC_BASE_URL): calls Pollinations.ai directly.
 * Optionally uses POLLINATIONS_API_KEY for higher rate limits.
 */

import fs from 'fs';
import https from 'https';
import http from 'http';
import path from 'path';

const DEFAULT_OUTPUT = '/workspace/group/generated-image.png';

function usage(): void {
  console.error('Usage: generate-image "<prompt>" [output-path]');
  process.exit(1);
}

/** Call generate-image via the credential proxy (container mode). */
async function callViaProxy(prompt: string, proxyBase: string): Promise<Buffer> {
  const url = new URL('/generate-image', proxyBase);
  const body = JSON.stringify({ prompt });

  return new Promise((resolve, reject) => {
    const isHttps = url.protocol === 'https:';
    const makeReq = isHttps ? https.request : http.request;

    const req = makeReq(
      {
        hostname: url.hostname,
        port: url.port || (isHttps ? 443 : 80),
        path: url.pathname,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (chunk: Buffer) => chunks.push(chunk));
        res.on('end', () => {
          if (res.statusCode !== 200) {
            const text = Buffer.concat(chunks).toString('utf-8');
            reject(new Error(`Proxy error ${res.statusCode}: ${text.slice(0, 500)}`));
            return;
          }
          resolve(Buffer.concat(chunks));
        });
      },
    );

    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

/** Call Pollinations.ai directly (standalone mode). */
async function callDirect(prompt: string): Promise<Buffer> {
  const apiKey = process.env.POLLINATIONS_API_KEY;
  const encoded = encodeURIComponent(prompt);
  const reqHeaders: Record<string, string> = {};
  if (apiKey) reqHeaders['Authorization'] = `Bearer ${apiKey}`;

  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: 'gen.pollinations.ai',
        path: `/image/${encoded}?model=flux&width=1024&height=1024`,
        method: 'GET',
        headers: reqHeaders,
      },
      (res) => {
        // Follow redirects (Pollinations may redirect)
        if (res.statusCode === 301 || res.statusCode === 302) {
          const location = res.headers['location'];
          if (!location) {
            reject(new Error('Redirect with no Location header'));
            return;
          }
          // Simple one-level redirect follow
          https.get(location, (r2) => {
            const chunks: Buffer[] = [];
            r2.on('data', (c: Buffer) => chunks.push(c));
            r2.on('end', () => resolve(Buffer.concat(chunks)));
            r2.on('error', reject);
          }).on('error', reject);
          return;
        }
        if (res.statusCode !== 200) {
          const chunks: Buffer[] = [];
          res.on('data', (c: Buffer) => chunks.push(c));
          res.on('end', () =>
            reject(new Error(`Pollinations error ${res.statusCode}: ${Buffer.concat(chunks).toString('utf-8').slice(0, 300)}`)),
          );
          return;
        }
        const chunks: Buffer[] = [];
        res.on('data', (chunk: Buffer) => chunks.push(chunk));
        res.on('end', () => resolve(Buffer.concat(chunks)));
      },
    );

    req.on('error', reject);
    req.end();
  });
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args.length < 1) usage();

  const prompt = args[0];
  const outputPath = args[1] || DEFAULT_OUTPUT;

  if (!prompt.trim()) {
    console.error('Error: prompt cannot be empty');
    process.exit(1);
  }

  console.error(`Generating image for: "${prompt}"`);
  console.error(`Output: ${outputPath}`);

  try {
    const proxyBase = process.env.ANTHROPIC_BASE_URL;
    const imageBuffer = proxyBase
      ? await callViaProxy(prompt, proxyBase)
      : await callDirect(prompt);

    const dir = path.dirname(outputPath);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(outputPath, imageBuffer);

    console.log(outputPath);
  } catch (err) {
    console.error(`Error: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  }
}

main();
