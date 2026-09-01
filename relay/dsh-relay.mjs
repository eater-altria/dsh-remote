#!/usr/bin/env node
/**
 * dsh-remote relay: exposes a loopback-only DSH web host to the LAN so the
 * Flutter mobile client can reach it.
 *
 *   - Listens on 0.0.0.0:<listenPort> (default 3081).
 *   - Forwards every HTTP request to 127.0.0.1:<targetPort> (default 3080),
 *     rewriting the Host header to the loopback authority so the request
 *     passes the host's `/api` browser-trust fence.
 *   - Tunnels WebSocket upgrades (the /api/remote.mux downlink) as raw
 *     sockets, with the same Host rewrite.
 *   - Upstream auth: dsh ≥ 0.1.2 requires browser-session auth on every
 *     request (HTTP and WS handshake). The phone app sends the launch token
 *     (from the `?token=` of the URL printed by `dsh web`) as the
 *     `x-dsh-token` header; the relay exchanges it upstream for the signed
 *     `dsh-auth-*` cookie and attaches that cookie to every forwarded
 *     request, re-exchanging when the cookie goes stale.
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

// ---------------------------------------------------------------------------
// 上游 dsh 鉴权（browser-session cookie，dsh ≥ 0.1.2 必需）
// ---------------------------------------------------------------------------
//
// dsh 0.1.2 起，host 的每个请求（/api 与 WS 握手都要）先过 browser-trust
// fence，再过 browser-session 认证：一个绑定 Host authority 的 HMAC 签名
// cookie。获取路径与浏览器一致——用 `dsh web` 启动时打印的 launch URL 里的
// token 交换：
//
//   GET http://<host>/?token=<launchToken>  →  303 + Set-Cookie: dsh-auth-*=...
//
// App 在主机配置里填该 token，随请求带 `x-dsh-token` 头；relay 用它完成
// 交换并缓存 cookie。cookie 跨 dsh 重启仍然有效（签名密钥持久化在 host 的
// 凭据库），直到自身过期；launch token 则是每进程随机，dsh 重启后 App 需要
// 更新 token 才能再次交换。
const upstreamAuth = { token: null, cookie: null, expiresAt: 0, pending: null, pendingToken: null };

/** 从入站请求取 dsh launch token（App 通过 x-dsh-token 头携带）。 */
function extractDshToken(req) {
  const header = req.headers['x-dsh-token'];
  return typeof header === 'string' && header !== '' ? header : null;
}

/** 用 launch token 向上游交换 browser-session cookie。 */
async function exchangeUpstreamCookie(token) {
  const res = await fetch(`http://${targetAuthority}/?token=${encodeURIComponent(token)}`, {
    redirect: 'manual',
    headers: { host: targetAuthority },
  });
  const setCookie = res.headers.get('set-cookie');
  await res.arrayBuffer().catch(() => {}); // 吸干响应体，释放连接
  if (res.status !== 303 || !setCookie) {
    throw new Error(`HTTP ${res.status}（launch token 无效——dsh 重启后需用新 URL 里的 token）`);
  }
  const pair = setCookie.split(';')[0];
  const maxAge = /(?:^|;\s*)Max-Age=(\d+)/i.exec(setCookie);
  return {
    cookie: pair,
    expiresAt: Date.now() + (maxAge ? Number(maxAge[1]) * 1000 : 24 * 3600e3),
  };
}

/**
 * 取可用的上游 cookie：缓存命中（同 token 且剩余有效期 >5min）直接返回，否则
 * 交换。forceRefresh 用于上游 401 后的强制重换。交换失败但旧 cookie 仍在
 * 有效期内时继续用旧的——dsh 重启会让 launch token 失效，但已铸 cookie
 * 未必过期。
 */
async function upstreamCookieFor(token, { forceRefresh = false } = {}) {
  const cache = upstreamAuth;
  if (!forceRefresh && cache.cookie && cache.token === token && cache.expiresAt - Date.now() > 300e3) {
    return cache.cookie;
  }
  if (!forceRefresh && cache.pending && cache.pendingToken === token) {
    return cache.pending;
  }
  const p = (async () => {
    try {
      const fresh = await exchangeUpstreamCookie(token);
      cache.token = token;
      cache.cookie = fresh.cookie;
      cache.expiresAt = fresh.expiresAt;
      console.log('[auth] exchanged dsh launch token for browser-session cookie');
      return fresh.cookie;
    } catch (err) {
      if (cache.cookie && cache.expiresAt > Date.now()) {
        console.warn(`[auth] dsh token exchange failed (${err.message}); using cached cookie`);
        return cache.cookie;
      }
      throw err;
    } finally {
      if (cache.pending === p) {
        cache.pending = null;
        cache.pendingToken = null;
      }
    }
  })();
  cache.pending = p;
  cache.pendingToken = token;
  return p;
}

/** 缓存的 cookie 被判失效（上游 401）时丢弃，下次请求重新交换。 */
function invalidateUpstreamCookie(token) {
  if (upstreamAuth.token === token) {
    upstreamAuth.cookie = null;
    upstreamAuth.expiresAt = 0;
  }
}

/** 读取完整请求体（有 dsh token 时缓冲，供 401 重试使用）。 */
async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks);
}

/** Headers safe to forward as-is (Host is rewritten separately). */
function forwardHeaders(req, cookie) {
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
  // x-dsh-token 是 relay 与 App 之间的凭证，不下泄给 host；host 要的是
  // 交换来的 browser-session cookie。手机端自身的 cookie 对上游 authority
  // 无意义，一律替换。
  delete headers['x-dsh-token'];
  if (cookie) headers.cookie = cookie;
  else delete headers.cookie;
  return headers;
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
//   DELETE /__relay/files/<id>  删除暂存文件（App 收件箱删除）
//   GET  /__relay/outbox        最近的推送列表（App 收件箱/补拉）
//   WS   /__relay/outbox        推送事件实时广播（{kind:'push', ...meta} / {kind:'delete', id}）
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

async function handleFileDelete(res, id) {
  if (!/^[A-Za-z0-9-]+$/.test(id)) {
    res.writeHead(400).end('bad id');
    return;
  }
  try {
    await fs.rm(path.join(filesStoreDir, id), { recursive: true, force: true });
    const idx = recentPushes.findIndex((m) => m.id === id);
    if (idx >= 0) recentPushes.splice(idx, 1);
    // 广播删除事件，其他在线设备可同步移除。
    const frame = JSON.stringify({ kind: 'delete', id });
    for (const socket of outboxSockets) {
      try {
        socket.write(encodeWsText(frame));
      } catch {}
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, id }));
  } catch (err) {
    res.writeHead(502, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: `delete failed: ${err.message}` }));
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
  if (fileMatch && req.method === 'DELETE') {
    handleFileDelete(res, fileMatch[1]);
    return;
  }
  if (req.url?.startsWith('/__relay/outbox') && req.method === 'GET') {
    handleOutboxList(res);
    return;
  }
  proxyToHost(req, res).catch((err) => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    res.end(`relay upstream error: ${err.message}`);
  });
});

/**
 * 透明转发到 host。携带 dsh token 时先交换/复用 browser-session cookie，
 * 并缓冲请求体以便在上游 401（缓存 cookie 失效）时刷新 cookie 重试一次
 * ——401 发生在 RPC 分发之前，重放不会重复执行。无 token 时保持原来的
 * 流式转发（旧版无鉴权 dsh 的行为不变）。
 */
async function proxyToHost(req, res) {
  const dshToken = extractDshToken(req);
  let cookie = null;
  let body = null;
  if (dshToken) {
    try {
      cookie = await upstreamCookieFor(dshToken);
    } catch (err) {
      res.writeHead(401, { 'content-type': 'text/plain; charset=utf-8' });
      res.end(`dsh upstream auth failed: ${err.message}`);
      return;
    }
    body = await readBody(req);
  }

  const attempt = (ck) =>
    new Promise((resolve) => {
      const headers = forwardHeaders(req, ck);
      if (body) headers['content-length'] = body.length;
      const upstream = http.request(
        {
          host: targetHost,
          port: targetPort,
          path: req.url,
          method: req.method,
          headers,
        },
        (upRes) => resolve(upRes),
      );
      upstream.on('error', () => resolve(null));
      if (body) upstream.end(body);
      else req.pipe(upstream);
    });

  let upRes = await attempt(cookie);
  if (upRes && upRes.statusCode === 401 && dshToken) {
    // 吸干 401 响应后强制重换 cookie 再试一次。
    upRes.resume();
    await new Promise((resolve) => upRes.on('end', resolve));
    invalidateUpstreamCookie(dshToken);
    try {
      cookie = await upstreamCookieFor(dshToken, { forceRefresh: true });
    } catch {
      cookie = null;
    }
    upRes = await attempt(cookie);
  }
  if (!upRes) {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    res.end('relay upstream error: connection failed');
    return;
  }
  res.writeHead(upRes.statusCode ?? 502, upRes.headers);
  upRes.pipe(res);
}

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
  tunnelUpgrade(req, socket, head).catch(() => socket.destroy());
});

/** WS 隧道：握手前备好上游 cookie；嗅探握手响应，401 则失效缓存 cookie。 */
async function tunnelUpgrade(req, socket, head) {
  const dshToken = extractDshToken(req);
  let cookie = null;
  if (dshToken) {
    try {
      cookie = await upstreamCookieFor(dshToken);
    } catch (err) {
      socket.write(`HTTP/1.1 401 Unauthorized\r\ncontent-type: text/plain; charset=utf-8\r\n\r\ndsh upstream auth failed: ${err.message}`);
      socket.destroy();
      return;
    }
  }
  const upstream = net.connect(targetPort, targetHost, () => {
    const lines = [`${req.method} ${req.url} HTTP/${req.httpVersion}`];
    const headers = forwardHeaders(req, cookie);
    // Preserve the WebSocket handshake headers verbatim.
    headers.connection = req.headers.connection ?? 'Upgrade';
    headers.upgrade = req.headers.upgrade ?? 'websocket';
    for (const [name, value] of Object.entries(headers)) {
      if (value === undefined) continue;
      lines.push(`${name}: ${Array.isArray(value) ? value.join(', ') : value}`);
    }
    upstream.write(lines.join('\r\n') + '\r\n\r\n');
    if (head?.length) upstream.write(head);
    if (dshToken) {
      // 握手 401 = 缓存 cookie 失效：丢弃，下次重连（App 有自动重连）即重新交换。
      let inspected = false;
      upstream.on('data', (chunk) => {
        if (inspected) return;
        inspected = true;
        if (/^HTTP\/1\.\d 401/.test(chunk.toString('latin1', 0, 32))) {
          invalidateUpstreamCookie(dshToken);
        }
      });
    }
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
}

server.listen(listenPort, '0.0.0.0', () => {
  const lanIps = Object.values(os.networkInterfaces())
    .flat()
    .filter((i) => i && i.family === 'IPv4' && !i.internal)
    .map((i) => i.address);
  console.log(`dsh-remote relay listening on 0.0.0.0:${listenPort} -> ${targetAuthority}`);
  console.log(relayToken ? '  auth: token required (DSH_RELAY_TOKEN)' : '  auth: OPEN (set DSH_RELAY_TOKEN to require a token)');
  console.log('  upstream: dsh >= 0.1.2 browser-session auth via x-dsh-token header (cookie exchange)');
  for (const ip of lanIps) {
    console.log(`  phone can reach: http://${ip}:${listenPort}`);
  }
});
