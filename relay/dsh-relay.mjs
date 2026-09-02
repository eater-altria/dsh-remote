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
import { createReadStream, statSync, readFileSync } from 'node:fs';
import { execFile, spawn } from 'node:child_process';
import path from 'node:path';
import crypto from 'node:crypto';

const listenPort = Number(process.argv[2] ?? process.env.DSH_RELAY_PORT ?? 3081);
const targetHost = process.argv[3] ?? process.env.DSH_TARGET_HOST ?? '127.0.0.1';
const targetPort = Number(process.argv[4] ?? process.env.DSH_TARGET_PORT ?? 3080);
const targetAuthority = `${targetHost}:${targetPort}`;

// 访问令牌：relay 会把 Host 改写成回环，等于把 loopback-only 的特权方法
// 暴露给局域网，因此**始终要求令牌**。令牌持久化在 ~/.dsh-remote/config.json
//（首次启动自动生成，0600 权限），App 主机配置里填它即可——它独立于 dsh 的
// launch token，跨 dsh/relay 重启不变。DSH_RELAY_TOKEN 环境变量可覆盖（调试）。
const configDir = path.join(os.homedir(), '.dsh-remote');
const configFile = path.join(configDir, 'config.json');
const relayToken = process.env.DSH_RELAY_TOKEN ?? (await loadOrCreateRelayToken());

async function loadOrCreateRelayToken() {
  // 用户手填的令牌优先：任何非空字符串都接受（重启绝不覆盖用户配置）。
  try {
    const existing = JSON.parse(await fs.readFile(configFile, 'utf8'));
    if (typeof existing.token === 'string' && existing.token.trim() !== '') {
      if (existing.token.length < 12) {
        console.warn('[auth] relay token in config is short; consider 16+ random chars');
      }
      return existing.token;
    }
  } catch {}
  const token = crypto.randomBytes(24).toString('base64url');
  await fs.mkdir(configDir, { recursive: true });
  // 原子写：tmp + rename，避免崩溃留下半个 JSON 导致下次误判重生成。
  const tmp = `${configFile}.tmp`;
  await fs.writeFile(tmp, JSON.stringify({ token }, null, 2), { mode: 0o600 });
  await fs.rename(tmp, configFile);
  console.log(`[auth] generated new relay token -> ${configFile}`);
  return token;
}

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
// cookie。relay 有两条获取路径：
//
// 1. **同机部署（默认）**：直接读 dsh 持久化的签名密钥
//   （~/.dsh/.credentials.yaml 的 client-connection/browser-session 记录），
//    按 dsh 的 cookie 格式自铸。密钥跨 dsh 重启不变 → 上游鉴权免维护、
//    跨重启自愈，App 不需要知道 dsh 的 launch token。
// 2. **远程 host**（DSH_TARGET_HOST 指向别的机器，读不到凭据文件）：退回
//    launch-token 交换——客户端带 x-dsh-token 头，relay 用 GET /?token=
//    换 cookie 并缓存（launch token 每进程随机，dsh 重启后失效）。
const upstreamAuth = { token: null, cookie: null, expiresAt: 0, pending: null, pendingToken: null };

const credentialsFile = process.env.DSH_CREDENTIALS_FILE
  ?? path.join(process.env.DSH_HOME ?? path.join(os.homedir(), '.dsh'), '.credentials.yaml');
const isLoopbackTarget = ['127.0.0.1', 'localhost', '::1', '[::1]'].includes(targetHost);

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}

let credentialCache = { mtimeMs: -1, secret: null };

/** 读取 dsh 凭据文件里的 browser-session 签名密钥（mtime 缓存，轮转自愈）。 */
function loadSigningSecret() {
  let stat;
  try {
    stat = statSync(credentialsFile);
  } catch {
    if (credentialCache.secret) credentialCache = { mtimeMs: -1, secret: null };
    return credentialCache.secret;
  }
  if (stat.mtimeMs === credentialCache.mtimeMs) return credentialCache.secret;
  let secret = null;
  try {
    const text = readFileSync(credentialsFile, 'utf8');
    const m = text.match(/client-connection\/browser-session:[\s\S]*?secret:\s*([A-Za-z0-9_-]+)/);
    if (m) {
      const padded = m[1] + '='.repeat((4 - (m[1].length % 4)) % 4);
      const decoded = Buffer.from(padded.replaceAll('-', '+').replaceAll('_', '/'), 'base64');
      if (decoded.length === 32 && b64url(decoded) === m[1]) secret = decoded;
    }
  } catch {}
  credentialCache = { mtimeMs: stat.mtimeMs, secret };
  return secret;
}

/**
 * 按 dsh 的 browser-session cookie 格式自铸（authority = relay 改写后的 Host）。
 * 每次调用重 stat 凭据文件，密钥轮换（dsh 重置凭据）自动跟随。
 */
function mintLocalCookie() {
  const secret = loadSigningSecret();
  if (!secret) return null;
  const name = 'dsh-auth-' + b64url(crypto.createHash('sha256').update(targetAuthority).digest());
  const now = Date.now();
  const body = b64url(Buffer.from(JSON.stringify({
    version: 1,
    authority: targetAuthority,
    issuedAt: now,
    expiresAt: now + 12 * 3600e3, // 12h，远小于 dsh 默认 30 天上限
  }), 'utf8'));
  const sig = b64url(crypto.createHmac('sha256', secret).update(body).digest());
  return `${name}=v1.${body}.${sig}`;
}

/** 从入站请求取 dsh launch token（远程 host 场景，App 通过 x-dsh-token 头携带）。 */
function extractDshToken(req) {
  const header = req.headers['x-dsh-token'];
  return typeof header === 'string' && header !== '' ? header : null;
}

/** 用 launch token 向上游交换 browser-session cookie（远程 host 兜底路径）。 */
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
 * launch-token 交换路径的 cookie 缓存：命中（同 token 且剩余有效期 >5min）直接
 * 返回，否则交换。forceRefresh 用于上游 401 后的强制重换。交换失败但旧 cookie
 * 仍在有效期内时继续用旧的——dsh 重启会让 launch token 失效，但已铸 cookie
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

/** 缓存的交换 cookie 被判失效（上游 401）时丢弃，下次请求重新交换。 */
function invalidateUpstreamCookie(token) {
  if (upstreamAuth.token === token) {
    upstreamAuth.cookie = null;
    upstreamAuth.expiresAt = 0;
  }
}

/**
 * 解析本次转发的上游 cookie：客户端带 x-dsh-token 走交换路径（远程 host），
 * 否则同机部署直接自铸。返回 null 表示无可用凭据（旧版 dsh 无鉴权，直接透传）。
 */
async function resolveUpstreamCookie(req, { forceRefresh = false } = {}) {
  const token = extractDshToken(req);
  if (token) return upstreamCookieFor(token, { forceRefresh });
  if (!isLoopbackTarget) return null;
  return mintLocalCookie();
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
// dsh 重启（App → relay → 本机 dsh 进程）
// ---------------------------------------------------------------------------
//
//   POST /__relay/restart-dsh   （同其他请求，走 relay 令牌鉴权）
//
// 流程：找到监听 targetPort 的 dsh 进程 → 记录其 cwd → SIGTERM（10s 不退
// 则 SIGKILL）→ 以同一 cwd spawn `dsh web --no-open`（detached，输出进
// ~/.dsh/dsh-relay-dsh.log）→ 等新 host 监听后返回。上游鉴权无需处理：
// 自铸 cookie 的签名密钥持久化在凭据文件里，跨重启依然有效。
//
// 注意：dsh 重启会杀掉 host 上的一切活跃会话连接（含本 relay 正在服务的
// 请求）；调用方应把它当「维护操作」对待。若 dsh 由其他 supervisor 托管并
// 自动拉起，可能与本流程拉起的实例争端口——本部署（dsh-doctor 不托管活跃
// 子进程）无此问题。

const dshLogFile = process.env.DSH_RESTART_LOG ?? path.join(os.homedir(), '.dsh', 'dsh-relay-dsh.log');
const restartCommand = process.env.DSH_RESTART_COMMAND ?? 'dsh web --no-open';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** 监听指定端口的进程 pid（lsof；macOS/Linux 通用）。找不到返回 null。 */
async function pidListeningOn(port) {
  try {
    const out = await execFileP('lsof', ['-nP', `-iTCP:${port}`, '-sTCP:LISTEN', '-t']);
    const pid = Number(out.trim().split('\n')[0]);
    return Number.isInteger(pid) && pid > 0 ? pid : null;
  } catch {
    return null;
  }
}

/** 读取进程的 cwd（lsof -d cwd -Fn 的 n 行）。 */
async function cwdOfPid(pid) {
  try {
    const out = await execFileP('lsof', ['-a', '-p', String(pid), '-d', 'cwd', '-Fn']);
    const line = out.split('\n').find((l) => l.startsWith('n') && l.length > 1 && l[1] === '/');
    return line ? line.slice(1) : null;
  } catch {
    return null;
  }
}

function execFileP(cmd, args) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, (err, stdout) => (err ? reject(err) : resolve(stdout)));
  });
}

/** 等端口上的旧进程退出（SIGTERM → 10s 后 SIGKILL）。 */
async function killPidOnPort(pid, port) {
  try {
    process.kill(pid, 'SIGTERM');
  } catch {
    return; // 已经退了
  }
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if ((await pidListeningOn(port)) !== pid) return;
    await sleep(300);
  }
  try {
    process.kill(pid, 'SIGKILL');
  } catch {}
  // SIGKILL 后等端口实际释放。
  const killDeadline = Date.now() + 5_000;
  while (Date.now() < killDeadline) {
    if ((await pidListeningOn(port)) == null) return;
    await sleep(200);
  }
  throw new Error(`port ${port} still occupied after SIGKILL`);
}

let restarting = false;

async function handleRestartDsh(req, res) {
  if (restarting) {
    res.writeHead(409, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'restart already in progress' }));
    return;
  }
  restarting = true;
  const startedAt = Date.now();
  try {
    const oldPid = await pidListeningOn(targetPort);
    const cwd = oldPid ? await cwdOfPid(oldPid) : null;
    if (oldPid) {
      console.log(`[restart-dsh] killing pid ${oldPid} (cwd: ${cwd ?? 'unknown'})`);
      await killPidOnPort(oldPid, targetPort);
    } else {
      console.log(`[restart-dsh] no process on port ${targetPort}, starting fresh`);
    }
    // detached + 输出进日志：relay 退出后 dsh 继续存活。
    // 先截断日志，保证日志只含本次启动的输出（排障用）。
    // 上游鉴权无需处理：自铸 cookie 的签名密钥持久化在凭据文件里，跨重启有效。
    const out = await fs.open(dshLogFile, 'w');
    const [cmd, ...args] = restartCommand.split(/\s+/);
    const child = spawn(cmd, args, {
      detached: true,
      stdio: ['ignore', out.fd, out.fd],
      cwd: cwd ?? os.homedir(),
      env: process.env,
    });
    child.unref();
    await out.close(); // spawn 已继承 fd 副本，relay 侧可以关闭
    console.log(`[restart-dsh] spawned '${restartCommand}' as pid ${child.pid}`);
    // 等新 host 开始监听再返回。
    const deadline = Date.now() + 90_000;
    while (Date.now() < deadline) {
      if (await pidListeningOn(targetPort)) break;
      await sleep(500);
    }
    const ready = (await pidListeningOn(targetPort)) != null;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      ok: true,
      oldPid,
      newPid: child.pid,
      cwd: cwd ?? null,
      ready,
      ms: Date.now() - startedAt,
    }));
  } catch (err) {
    res.writeHead(502, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: `restart-dsh failed: ${err.message}` }));
  } finally {
    restarting = false;
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
  if (req.url === '/__relay/restart-dsh' && req.method === 'POST') {
    handleRestartDsh(req, res);
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
 * 透明转发到 host。上游 cookie 由 resolveUpstreamCookie 解析（x-dsh-token
 * 交换 或 本机凭据自铸）；有 cookie 时缓冲请求体，以便上游 401 时刷新
 * cookie 重试一次——401 发生在 RPC 分发之前，重放不会重复执行。
 * 完全无凭据（旧版无鉴权 dsh）时保持原来的流式转发。
 */
async function proxyToHost(req, res) {
  const dshToken = extractDshToken(req);
  let cookie = null;
  let body = null;
  try {
    cookie = await resolveUpstreamCookie(req);
  } catch (err) {
    res.writeHead(401, { 'content-type': 'text/plain; charset=utf-8' });
    res.end(`dsh upstream auth failed: ${err.message}`);
    return;
  }
  if (cookie) body = await readBody(req);

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
  if (upRes && upRes.statusCode === 401 && cookie) {
    // 吸干 401 响应后刷新 cookie 再试一次。
    upRes.resume();
    await new Promise((resolve) => upRes.on('end', resolve));
    if (dshToken) invalidateUpstreamCookie(dshToken);
    try {
      cookie = await resolveUpstreamCookie(req, { forceRefresh: true });
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
  try {
    cookie = await resolveUpstreamCookie(req);
  } catch (err) {
    socket.write(`HTTP/1.1 401 Unauthorized\r\ncontent-type: text/plain; charset=utf-8\r\n\r\ndsh upstream auth failed: ${err.message}`);
    socket.destroy();
    return;
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
  console.log(`  auth: relay token required (${process.env.DSH_RELAY_TOKEN ? 'DSH_RELAY_TOKEN env' : configFile})`);
  console.log(`  relay token: ${relayToken}`);
  console.log(isLoopbackTarget
    ? '  upstream: browser-session cookie minted from dsh credentials (auto, survives restarts)'
    : '  upstream: x-dsh-token header -> cookie exchange (remote target)');
  for (const ip of lanIps) {
    console.log(`  phone can reach: http://${ip}:${listenPort}`);
  }
});
