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
import { createReadStream } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

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

// ---------------------------------------------------------------------------
// 文件推送（agent → 手机系统下载器）
// ---------------------------------------------------------------------------
//
//   POST /__relay/push          {path, title?}  仅 loopback 调用（agent 在本机）
//   GET  /__relay/files/<id>    下载（?token= 或 x-relay-token 头）
//   GET  /__relay/outbox        最近的推送列表（App 收件箱/补拉）
//   WS   /__relay/outbox        推送事件实时广播（{kind:'push', ...meta}）
//
// 暂存目录：~/.dsh/dsh-remote-files/<id>/<原文件名> + meta.json。

const filesStoreDir = path.join(os.homedir(), '.dsh', 'dsh-remote-files');
const outboxSockets = new Set();
const recentPushes = []; // 内存收件箱（最多保留 50 条）

async function handlePush(req, res) {
  // 推送只能由主机本机发起（agent 运行在 host 上）。
  const remote = req.socket.remoteAddress;
  if (remote !== '127.0.0.1' && remote !== '::1' && remote !== '::ffff:127.0.0.1') {
    res.writeHead(403, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'push is loopback-only' }));
    return;
  }
  try {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
    const srcPath = body.path;
    if (typeof srcPath !== 'string' || !path.isAbsolute(srcPath)) {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: 'path must be an absolute path' }));
      return;
    }
    const stat = await fs.stat(srcPath);
    if (!stat.isFile()) throw new Error('not a regular file');
    const id = crypto.randomUUID();
    const name = path.basename(srcPath);
    const dir = path.join(filesStoreDir, id);
    await fs.mkdir(dir, { recursive: true });
    await fs.copyFile(srcPath, path.join(dir, name));
    const meta = {
      id,
      name,
      bytes: stat.size,
      title: typeof body.title === 'string' ? body.title : name,
      ts: Date.now(),
    };
    await fs.writeFile(path.join(dir, 'meta.json'), JSON.stringify(meta, null, 2));
    recentPushes.push(meta);
    if (recentPushes.length > 50) recentPushes.shift();
    // 广播给所有 outbox 订阅者（手机 App）。
    const frame = JSON.stringify({ kind: 'push', ...meta });
    for (const socket of outboxSockets) {
      try {
        socket.write(encodeWsText(frame));
      } catch {}
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(meta));
  } catch (err) {
    res.writeHead(502, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: `push failed: ${err.message}` }));
  }
}

async function handleFileDownload(req, res, id) {
  if (!/^[A-Za-z0-9-]+$/.test(id)) {
    res.writeHead(400).end('bad id');
    return;
  }
  try {
    const dir = path.join(filesStoreDir, id);
    const meta = JSON.parse(await fs.readFile(path.join(dir, 'meta.json'), 'utf8'));
    const filePath = path.join(dir, meta.name);
    const stat = await fs.stat(filePath);
    res.writeHead(200, {
      'content-type': 'application/octet-stream',
      'content-length': stat.size,
      'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(meta.name)}`,
    });
    createReadStream(filePath).pipe(res);
  } catch {
    res.writeHead(404).end('not found');
  }
}

function handleOutboxList(res) {
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ items: recentPushes.slice().reverse() }));
}

/** 最小 RFC6455 文本帧编码（服务器→客户端，无掩码）。 */
function encodeWsText(text) {
  const payload = Buffer.from(text, 'utf8');
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x81, len]);
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payload]);
}

/** relay 自己的 WS 握手（不转发 host）：/__relay/outbox 推送广播。 */
function handleOutboxUpgrade(req, socket) {
  const key = req.headers['sec-websocket-key'];
  if (!key) {
    socket.destroy();
    return;
  }
  const accept = crypto
    .createHash('sha1')
    .update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    .digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  outboxSockets.add(socket);
  // 连接即补发最近推送（断线重连不缺通知）。
  for (const meta of recentPushes.slice(-5)) {
    socket.write(encodeWsText(JSON.stringify({ kind: 'push', ...meta })));
  }
  // 客户端帧不解析（推送是纯下行）；关闭/错误即清理。
  socket.on('data', () => {});
  socket.on('close', () => outboxSockets.delete(socket));
  socket.on('error', () => outboxSockets.delete(socket));
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
  if (req.url === '/__relay/push' && req.method === 'POST') {
    handlePush(req, res);
    return;
  }
  const fileMatch = req.url?.match(/^\/__relay\/files\/([A-Za-z0-9-]+)/);
  if (fileMatch && req.method === 'GET') {
    handleFileDownload(req, res, fileMatch[1]);
    return;
  }
  if (req.url?.startsWith('/__relay/outbox') && req.method === 'GET') {
    handleOutboxList(res);
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
  // relay 自己的推送通道不转发 host。
  if (req.url === '/__relay/outbox') {
    handleOutboxUpgrade(req, socket);
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
