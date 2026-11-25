#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { RobloxBridge } from "./bridge.js";
import { registerTools } from "./tools.js";

async function main() {
  const bridge = new RobloxBridge();
  await bridge.start();

  const server = new McpServer({
    name: "mint-roblox-mcp",
    version: "0.1.0",
  });

  registerTools(server, bridge);

  const transport = new StdioServerTransport();
  await server.connect(transport);

  // eslint-disable-next-line no-console
  console.error("[mint] MCP server connected over stdio");

  const shutdown = async () => {
    try {
      await bridge.stop();
    } catch {
      // ignore
    }
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error("[mint] Fatal error:", err);
  process.exit(1);
});
