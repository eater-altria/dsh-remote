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

const listenPort = Number(process.argv[2] ?? process.env.DSH_RELAY_PORT ?? 3081);
const targetHost = process.argv[3] ?? process.env.DSH_TARGET_HOST ?? '127.0.0.1';
const targetPort = Number(process.argv[4] ?? process.env.DSH_TARGET_PORT ?? 3080);
const targetAuthority = `${targetHost}:${targetPort}`;

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

const server = http.createServer((req, res) => {
  if (req.url === '/__relay/history.slim' && req.method === 'POST') {
    handleSlimHistory(req, res);
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
  for (const ip of lanIps) {
    console.log(`  phone can reach: http://${ip}:${listenPort}`);
  }
});
