// Postiz AI rewrite-proxy. Runs as a sidecar to the postiz monolith.
// Postiz's openai-node SDK reads process.env.OPENAI_BASE_URL — we point
// it at http://localhost:8080/v1. This server intercepts every chat call,
// rewrites the hardcoded 'gpt-4.1' model to 'minimax/minimax-m3' on
// OpenRouter, and forwards. The OpenRouter key is taken from
// OPENAI_API_KEY (Postiz uses the same env var for the SDK bearer token).
//
// REWRITE MAP — only one entry by design:
//   'gpt-4.1'            → 'minimax/minimax-m3'
// Any other model name (including 'chatgpt-image-latest') passes through
// unchanged. OpenRouter will 404 unknown names, which is the loud-failure
// behavior we want for unsupported features (e.g. AI image generation).
//
// Required env:
//   OPENAI_API_KEY   — OpenRouter API key (forwarded as Authorization: Bearer)
// Optional:
//   OPENROUTER_BASE  — default https://openrouter.ai/api/v1
//   OPENAI_REFERER   — sent as HTTP-Referer for OpenRouter analytics
//   OPENAI_TITLE     — sent as X-Title for OpenRouter analytics

import express from 'express';
import { Readable } from 'node:stream';

// Locked rewrite map. Add entries only when Postiz's hardcoded model
// names actually change upstream — don't speculate.
const MODEL_MAP = Object.freeze({
  'gpt-4.1': 'minimax/minimax-m3',
});

const PORT = 8080;
const UPSTREAM = process.env.OPENROUTER_BASE || 'https://openrouter.ai/api/v1';
const KEY = process.env.OPENAI_API_KEY;
if (!KEY) {
  console.error('FATAL: OPENAI_API_KEY not set');
  process.exit(1);
}

console.log(`[startup] postiz-ai-proxy v0.1.0`);
console.log(`[startup] binding 0.0.0.0:${PORT}`);
console.log(`[startup] upstream=${UPSTREAM}`);
console.log(`[startup] rewrite map: ${JSON.stringify(MODEL_MAP)}`);

const app = express();
// 10MB body cap — Postiz's requests are small (chat prompts), but a
// generous limit avoids surprises if a future Postiz feature sends more.
app.use(express.json({ limit: '10mb' }));

// Health endpoint. MUST stay above the catch-all app.use() below, which
// forwards every remaining path upstream. Without this, a kubelet probe
// on any path is proxied to OpenRouter and comes back 404 — which is
// exactly what crash-looped this sidecar 1961 times on 2026-09-11.
// The deployment currently probes via tcpSocket because the running
// 0.1.0 image predates this route; switch it to httpGet /healthz when
// the image is rebuilt and the tag bumped.
app.get('/healthz', (_req, res) => res.status(200).json({ status: 'ok' }));

app.use(async (req, res) => {
  // Rewrite model field if it's a hardcoded name Postiz sends.
  let requestedModel = req.body?.model;
  let resolvedModel = requestedModel;
  if (typeof requestedModel === 'string' && MODEL_MAP[requestedModel]) {
    resolvedModel = MODEL_MAP[requestedModel];
    req.body.model = resolvedModel;
  }

  // Build the upstream URL. UPSTREAM already ends in /v1 and
  // req.originalUrl starts with /v1 (because OPENAI_BASE_URL ends with
  // /v1 and Postiz hits e.g. .../v1/chat/completions). Strip the
  // duplicate prefix so we don't end up at /v1/v1/chat/completions.
  const path = req.originalUrl.replace(/^\/v1(?=\/|$)/, '') || '/';

  // Per-request log line so you can grep to confirm M3 is what's being
  // called. Format chosen to be easy to grep + parse: one line per request.
  const reqId = Math.random().toString(36).slice(2, 10);
  console.log(`[req ${reqId}] ${req.method} ${req.originalUrl} model=${requestedModel}${resolvedModel !== requestedModel ? `→${resolvedModel}` : ''} → upstream=${UPSTREAM}${path}`);

  try {
    const upstreamRes = await fetch(`${UPSTREAM}${path}`, {
      method: req.method,
      headers: {
        'Authorization': `Bearer ${KEY}`,
        'Content-Type': 'application/json',
        'HTTP-Referer': process.env.OPENAI_REFERER || 'https://postiz.rubiconetic.com',
        'X-Title': process.env.OPENAI_TITLE || 'Postiz',
      },
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : JSON.stringify(req.body),
    });

    // Forward status + headers + body. Strip hop-by-hop headers.
    res.status(upstreamRes.status);
    upstreamRes.headers.forEach((v, k) => {
      if (['content-encoding', 'transfer-encoding', 'connection'].includes(k)) return;
      res.setHeader(k, v);
    });
    if (upstreamRes.body) {
      Readable.fromWeb(upstreamRes.body).pipe(res);
    } else {
      res.end();
    }

    // Log completion status once the response is fully streamed.
    res.on('finish', () => {
      console.log(`[req ${reqId}] ← ${upstreamRes.status}`);
    });
  } catch (err) {
    console.error(`[req ${reqId}] upstream error: ${err.message}`);
    res.status(502).json({ error: { message: `proxy upstream error: ${err.message}`, type: 'proxy_error' } });
  }
});

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`[ready] listening on 0.0.0.0:${PORT}`);
});

// Graceful shutdown for clean pod termination.
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    console.log(`[shutdown] ${sig} received, closing`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 5000).unref();
  });
}