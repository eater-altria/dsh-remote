#!/usr/bin/env node
/**
 * dsh-remote relay: exposes a loopback-only DSH web host to the LAN so the
 * Flutter mobile client can reach it.
 *
 *   - Listens on 0.0.0.0:<listenPort> (default 3081).
 *   - Forwards every HTTP request to 127.0.0.1:<targetPort> (default 3080),
 *     rewriting the Host header to the loopback authority so the request
 *     passes the host's `/api` browser-trust fence.
 *   - Tunnels WebSocket upgrades (the /api/events.mux and /api/events.host
 *     downlinks) as raw sockets, with the same Host rewrite.
 *
 * Usage: node relay/dsh-relay.mjs [listenPort] [targetPort]
 * Env:   DSH_RELAY_PORT, DSH_TARGET_PORT, DSH_TARGET_HOST
 */
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import fs from 'node:fs/promises';
import path from 'node:path';

const listenPort = Number(process.argv[2] ?? process.env.DSH_RELAY_PORT ?? 3081);
const targetHost = process.argv[3] ?? process.env.DSH_TARGET_HOST ?? '127.0.0.1';
const targetPort = Number(process.argv[4] ?? process.env.DSH_TARGET_PORT ?? 3080);
const targetAuthority = `${targetHost}:${targetPort}`;

// 可选访问令牌：relay 会把 Host 改写成回环，等于把 loopback-only 的特权方法
// 暴露给局域网——设置 DSH_RELAY_TOKEN 后，所有请求（含 WS 握手）必须携带
// `x-relay-token: <token>` 头或 `?token=<token>` 查询参数。
const relayToken = process.env.DSH_RELAY_TOKEN ?? null;

function authorized(req) {
  if (!relayToken) return true;
  if (req.headers['x-relay-token'] === relayToken) return true;
  try {
    return new URL(req.url, 'http://x').searchParams.get('token') === relayToken;
  } catch {
    return false;
  }
}

/** Headers safe to forward as-is (Host is rewritten separately). */
function forwardHeaders(req) {
  const headers = { ...req.headers };
  headers.host = targetAuthority;
  // The relay terminates the client TCP connection; do not leak hop-by-hop
  // headers into the upstream request.
  delete headers['connection'];
  delete headers['keep-alive'];
  delete headers['proxy-authorization'];
  delete headers['te'];
  delete headers['trailer'];
  delete headers['transfer-encoding'];
  delete headers['upgrade'];
  return headers;
}

/**
 * Relay-side slim history: proxies session.history upstream, strips the
 * transient `assistant/chunk` events and bulky `replayState` blobs from the
 * page before sending it to the phone. A 200-message raw page can be ~9 MB
 * (40k chunk events); the slim form is typically 95%+ smaller, which removes
 * the multi-second UI-thread jsonDecode freeze on the client.
 *
 *   POST /__relay/history.slim
 *   body: { sessionId, beforeSeq?, maxMessages? }
 *   response: the session.history ServerResponse `result.value` (slimmed),
 *             plus `slim: true`.
 */
async function handleSlimHistory(req, res) {
  try {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
    const envelope = {
      type: 'client-request',
      rpcId: `relay-slim-${Date.now()}`,
      method: 'session.history',
      payload: {
        sessionId: body.sessionId,
        ...(body.beforeSeq !== undefined ? { beforeSeq: body.beforeSeq } : {}),
        maxMessages: body.maxMessages ?? 60,
      },
    };
    const upstream = await fetch(`http://${targetAuthority}/api/session.history`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', host: targetAuthority },
      body: JSON.stringify(envelope),
    });
    const text = await upstream.text();
    if (upstream.status !== 200) {
      res.writeHead(upstream.status, { 'content-type': 'application/json' });
      res.end(text);
      return;
    }
    const decoded = JSON.parse(text);
    const value = decoded?.result?.ok ? decoded.result.value : null;
    if (!value || !Array.isArray(value.events)) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(text);
      return;
    }
    const slimEvents = [];
    for (const entry of value.events) {
      const event = entry?.event;
      if (!event || event.type === 'assistant/chunk') continue;
      // replayState 是宿主重放内部状态（可含完整请求体），客户端 fold 用不到。
      const message = event.data?.message;
      if (message?.source?.replayState) delete message.source.replayState;
      slimEvents.push(entry);
    }
    const before = text.length;
    value.events = slimEvents;
    value.slim = true;
    console.log(`[slim] ${body.sessionId} max=${envelope.payload.maxMessages}: ${before} -> ${JSON.stringify(value).length} bytes, ${slimEvents.length} events`);
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(value));
  } catch (err) {
    res.writeHead(502, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: `slim history failed: ${err.message}` }));
  }
}

/**
 * Relay-side directory browser: serves the dsh-remote App's workspace
 * directory picker without touching the host's directory-picker seam
 * (the host's native chooser is reserved for the Web GUI on the operator's
 * display). Mirrors the host.listDirectory wire shape:
 *
 *   GET /__relay/listDir?path=/abs/dir   (absent path = home)
 *   → { path, home, crumbs: [{name, path, hidden}], entries: [...], truncated }
 *
 * Directories only, name-sorted, symlinks-to-directories followed, broken or
 * cyclic links skipped; hidden = dot-prefixed; capped at 1000 entries.
 */
async function handleListDir(req, res) {
  try {
    const url = new URL(req.url, 'http://x');
    const home = os.homedir();
    const target = url.searchParams.get('path') || home;
    if (!path.isAbsolute(target)) {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'path must be absolute' }));
      return;
    }
    const dirents = await fs.readdir(target, { withFileTypes: true });
    const entries = [];
    let truncated = false;
    for (const d of dirents) {
      if (entries.length >= 1000) {
        truncated = true;
        break;
      }
      // 只收目录；目录符号链接跟随，stat 失败（断链/环链/权限）跳过。
      let isDir = d.isDirectory();
      if (d.isSymbolicLink()) {
        try {
          isDir = (await fs.stat(path.join(target, d.name))).isDirectory();
        } catch {
          continue;
        }
      }
      if (!isDir) continue;
      entries.push({ name: d.name, path: path.join(target, d.name), hidden: d.name.startsWith('.') });
    }
    entries.sort((a, b) => a.name.localeCompare(b.name));
    // 面包屑：从根到目标的祖先链（根 crumb 用完整路径名）。
    const crumbs = [];
    const parts = path.resolve(target).split(path.sep).filter(Boolean);
    let acc = path.sep;
    crumbs.push({ name: path.sep, path: path.sep, hidden: false });
    for (const part of parts) {
      acc = path.join(acc, part);
      crumbs.push({ name: part, path: acc, hidden: false });
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ path: target, home, crumbs, entries, truncated }));
  } catch (err) {
    res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: `listDir failed: ${err.message}` }));
  }
}

const server = http.createServer((req, res) => {
  if (!authorized(req)) {
    res.writeHead(401, { 'content-type': 'text/plain' });
    res.end('unauthorized: missing or invalid relay token');
    return;
  }
  if (req.url === '/__relay/history.slim' && req.method === 'POST') {
    handleSlimHistory(req, res);
    return;
  }
  if (req.url?.startsWith('/__relay/listDir') && req.method === 'GET') {
    handleListDir(req, res);
    return;
  }
  const upstream = http.request(
    {
      host: targetHost,
      port: targetPort,
      path: req.url,
      method: req.method,
      headers: forwardHeaders(req),
    },
    (upRes) => {
      res.writeHead(upRes.statusCode ?? 502, upRes.headers);
      upRes.pipe(res);
    },
  );
  upstream.on('error', (err) => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    res.end(`relay upstream error: ${err.message}`);
  });
  req.pipe(upstream);
});

server.on('upgrade', (req, socket, head) => {
  if (!authorized(req)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
    socket.destroy();
    return;
  }
  const upstream = net.connect(targetPort, targetHost, () => {
    const lines = [`${req.method} ${req.url} HTTP/${req.httpVersion}`];
    const headers = forwardHeaders(req);
    // Preserve the WebSocket handshake headers verbatim.
    headers.connection = req.headers.connection ?? 'Upgrade';
    headers.upgrade = req.headers.upgrade ?? 'websocket';
    for (const [name, value] of Object.entries(headers)) {
      if (value === undefined) continue;
      lines.push(`${name}: ${Array.isArray(value) ? value.join(', ') : value}`);
    }
    upstream.write(lines.join('\r\n') + '\r\n\r\n');
    if (head?.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
});

server.listen(listenPort, '0.0.0.0', () => {
  const lanIps = Object.values(os.networkInterfaces())
    .flat()
    .filter((i) => i && i.family === 'IPv4' && !i.internal)
    .map((i) => i.address);
  console.log(`dsh-remote relay listening on 0.0.0.0:${listenPort} -> ${targetAuthority}`);
  console.log(relayToken ? '  auth: token required (DSH_RELAY_TOKEN)' : '  auth: OPEN (set DSH_RELAY_TOKEN to require a token)');
  for (const ip of lanIps) {
    console.log(`  phone can reach: http://${ip}:${listenPort}`);
  }
});
