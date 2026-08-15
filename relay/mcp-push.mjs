#!/usr/bin/env node
// dsh-remote 推送 MCP shim：stdio MCP server，向 agent 暴露 push_to_phone 工具。
// 注意：MCP 协议消息只能走 stdout，任何日志一律写 stderr（console.error）。
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const relayBase = process.env.DSH_RELAY_URL ?? 'http://127.0.0.1:3081';
const relayToken = process.env.DSH_RELAY_TOKEN ?? '';

const RELAY_DOWN_MSG =
  'dsh-remote relay 未运行。请让用户启动：`node ~/projects/dsh-remote/relay/dsh-relay.mjs`（或确认 launchd 服务 ai.deepseek.dsh-remote-relay 已加载）。';

const server = new McpServer({ name: 'dsh-remote', version: '0.1.0' });

server.registerTool(
  'push_to_phone',
  {
    description:
      '把本机文件推送到主人的手机（dsh-remote App 会弹出接收提示，走系统下载器保存）。' +
      '当用户说「推送给我 / 发到手机 / 传给我」时调用。',
    inputSchema: {
      path: z.string().describe('要推送的本机文件绝对路径'),
      title: z.string().optional().describe('可选标题，显示在手机的接收提示里'),
    },
  },
  async ({ path: filePath, title }) => {
    let resp;
    try {
      resp = await fetch(`${relayBase}/__relay/push`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          ...(relayToken ? { 'x-relay-token': relayToken } : {}),
        },
        body: JSON.stringify({ path: filePath, ...(title ? { title } : {}) }),
      });
    } catch {
      return { content: [{ type: 'text', text: RELAY_DOWN_MSG }], isError: true };
    }
    const data = await resp.json().catch(() => null);
    if (!resp.ok || !data?.id) {
      return {
        content: [{ type: 'text', text: `推送失败：${data?.error ?? `HTTP ${resp.status}`}` }],
        isError: true,
      };
    }
    return {
      content: [
        {
          type: 'text',
          text: `已推送到手机：${data.name}（${(data.bytes / 1024).toFixed(1)} KB）。` +
            `手机端 App 会弹出接收提示，确认后由系统下载器保存到「下载」目录。`,
        },
      ],
    };
  },
);

await server.connect(new StdioServerTransport());
console.error(`[dsh-remote] push mcp ready, relay=${relayBase}`);
