#!/usr/bin/env node
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js";

const DEFAULT_STDIO_TARGET = "npx -y @modelcontextprotocol/server-everything";

const USAGE = `用法：
  mcp-client tools [选项]
  mcp-client call <工具名> [参数JSON] [选项]

选项：
  --stdio "<命令及参数>"  通过 stdio 启动本地 MCP server，例如
                          --stdio "npx -y @modelcontextprotocol/server-everything"
  --cwd <目录>            stdio server 的工作目录
  --url <地址>            连接远程 Streamable HTTP MCP server
  --header "名: 值"       远程连接的请求头，可重复，例如 --header "Authorization: Bearer xxx"
  --json '<对象>'         call 的参数，等价于位置参数形式
  --help                  显示本帮助

示例：
  npm run dev -- tools --stdio "npx -y @modelcontextprotocol/server-everything"
  npm run dev -- call add --json '{"a":3,"b":4}' --stdio "npx -y @modelcontextprotocol/server-everything"
  npm run dev -- tools --url https://example.com/mcp --header "Authorization: Bearer xxx"
`;

type Flags = Map<string, string[]>;

type ParsedArgs = {
  positional: string[];
  flags: Flags;
};

function parseArgs(argv: string[]): ParsedArgs {
  const positional: string[] = [];
  const flags: Flags = new Map();
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (token === undefined) continue;
    if (!token.startsWith("--")) {
      positional.push(token);
      continue;
    }
    const eq = token.indexOf("=");
    let name: string;
    let value: string | undefined;
    if (eq !== -1) {
      name = token.slice(2, eq);
      value = token.slice(eq + 1);
    } else {
      name = token.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("--")) {
        value = next;
        i++;
      }
    }
    if (value === undefined) {
      throw new Error(`选项 --${name} 缺少取值`);
    }
    const list = flags.get(name);
    if (list) list.push(value);
    else flags.set(name, [value]);
  }
  return { positional, flags };
}

function lastValue(flags: Flags, name: string): string | undefined {
  const list = flags.get(name);
  return list?.[list.length - 1];
}

function buildTransport(flags: Flags): Transport {
  const url = lastValue(flags, "url");
  if (url !== undefined) {
    const headers: Record<string, string> = {};
    for (const raw of flags.get("header") ?? []) {
      const sep = raw.indexOf(":");
      if (sep === -1) throw new Error(`--header 需为 "名: 值" 格式，收到：${raw}`);
      headers[raw.slice(0, sep).trim()] = raw.slice(sep + 1).trim();
    }
    return new StreamableHTTPClientTransport(new URL(url), { requestInit: { headers } });
  }

  const target = (lastValue(flags, "stdio") ?? DEFAULT_STDIO_TARGET).trim();
  const parts = target.split(/\s+/);
  const command = parts[0];
  if (command === undefined || command === "") {
    throw new Error("--stdio 不能为空");
  }
  return new StdioClientTransport({
    command,
    args: parts.slice(1),
    cwd: lastValue(flags, "cwd"),
    stderr: "inherit",
  });
}

function describeParameters(schema: {
  properties?: Record<string, object> | undefined;
  required?: string[] | undefined;
}): string {
  const properties = schema.properties ?? {};
  const required = new Set(schema.required ?? []);
  const names = Object.keys(properties);
  if (names.length === 0) return "      参数：无";
  const lines = names.map((name) => {
    const raw = properties[name] as { type?: string; description?: string } | undefined;
    const type = raw?.type ?? "any";
    const mark = required.has(name) ? "必填" : "可选";
    const desc = raw?.description ? ` - ${raw.description}` : "";
    return `        ${name}: ${type} (${mark})${desc}`;
  });
  return ["      参数：", ...lines].join("\n");
}

function renderContent(content: unknown[]): string {
  const parts: string[] = [];
  for (const item of content) {
    const block = item as { type?: string; text?: string; mimeType?: string; data?: string; uri?: string };
    if (block.type === "text" && typeof block.text === "string") {
      parts.push(block.text);
    } else if (block.type === "image" && typeof block.data === "string") {
      parts.push(`<图片 ${block.mimeType ?? "未知类型"}，base64 ${block.data.length} 字符>`);
    } else if (block.type === "resource" && typeof block.uri === "string") {
      parts.push(`<资源 ${block.uri}>`);
    } else {
      parts.push(JSON.stringify(item));
    }
  }
  return parts.join("\n");
}

async function main(): Promise<void> {
  const { positional, flags } = parseArgs(process.argv.slice(2));
  const subcommand = positional[0];
  if (subcommand === undefined || subcommand === "help" || flags.has("help")) {
    process.stdout.write(USAGE);
    return;
  }

  const client = new Client({ name: "mcp-client", version: "0.1.0" }, { capabilities: {} });
  await client.connect(buildTransport(flags));

  try {
    const version = client.getServerVersion();
    process.stderr.write(
      `已连接 ${version?.name ?? "未知 server"} ${version?.version ?? ""}\n`,
    );

    if (subcommand === "tools") {
      const { tools } = await client.listTools();
      if (tools.length === 0) {
        console.log("该 server 未提供任何工具。");
        return;
      }
      console.log(`可用工具（${tools.length} 个）：`);
      for (const tool of tools) {
        console.log(`  - ${tool.name}`);
        if (tool.description) console.log(`      说明：${tool.description}`);
        console.log(describeParameters(tool.inputSchema));
      }
      return;
    }

    if (subcommand === "call") {
      const toolName = positional[1];
      if (toolName === undefined) {
        throw new Error("call 需要提供工具名，例如：call add --json '{\"a\":1,\"b\":2}'");
      }
      const rawArgs = lastValue(flags, "json") ?? positional[2] ?? "{}";
      let args: Record<string, unknown>;
      try {
        const parsed: unknown = JSON.parse(rawArgs);
        if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
          throw new Error("参数必须是 JSON 对象");
        }
        args = parsed as Record<string, unknown>;
      } catch (error) {
        throw new Error(`参数 JSON 解析失败：${(error as Error).message}`);
      }

      const result = await client.callTool({ name: toolName, arguments: args });
      console.log(renderContent(result.content as unknown[]));
      if (result.structuredContent !== undefined) {
        console.log(JSON.stringify(result.structuredContent, null, 2));
      }
      if (result.isError) {
        process.exitCode = 1;
      }
      return;
    }

    throw new Error(`未知子命令：${subcommand}（可用：tools、call）`);
  } finally {
    await client.close();
  }
}

main().catch((error: unknown) => {
  process.stderr.write(`错误：${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
