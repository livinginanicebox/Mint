# Mint

Mint is an open-source **MCP (Model Context Protocol) bridge** that connects AI clients like **Arena AI** to **Roblox Studio**. It lets an MCP-compatible client inspect your open place, edit scripts, create instances, set properties, and run Luau commands through a local Roblox Studio plugin.

> **Status:** Early preview. The download website is ready; a packaged Windows `.exe` installer is **not available yet**.

## What’s in this repo

| Path | Purpose |
|------|---------|
| `src/` | Node.js/TypeScript MCP server + local HTTP bridge |
| `plugin/` | Roblox Studio plugin (`.rbxmx` and `.server.lua` source) |
| `docs/` | GitHub Pages download/setup website |
| `package.json` | Server package manifest |

## How it works

1. **MCP client** (Arena AI or another MCP-compatible client) starts Mint over stdio.
2. **Mint MCP server** exposes Roblox Studio tools over MCP and runs a local bridge on `127.0.0.1:5123`.
3. **Mint Roblox Studio plugin** long-polls the local bridge, executes commands in Studio, and posts results back.

Roblox Studio plugins can only make outbound HTTP requests, so the plugin polls the local bridge instead of exposing an inbound port from Studio.

## Quick start

### 1. Install dependencies

```bash
npm install
npm run build
```

Requires **Node.js 18+**.

### 2. Install the Roblox Studio plugin

1. Copy `plugin/MintMCPPlugin.rbxmx` into your Roblox Studio plugins folder.
2. Restart Roblox Studio (or reload plugins).
3. Open a place and click the **Mint MCP** toolbar button to connect.

> Make sure HTTP requests are allowed for plugins in your Studio settings if your environment restricts them.

### 3. Add Mint to your MCP client

Example stdio MCP configuration:

```json
{
  "mcpServers": {
    "mint-roblox": {
      "command": "node",
      "args": ["/absolute/path/to/Mint/dist/index.js"],
      "env": {
        "MINT_BRIDGE_PORT": "5123"
      }
    }
  }
}
```

Use the absolute path to `dist/index.js` on your machine.

For **Arena AI**, add Mint as a local MCP server using the same stdio configuration your Arena MCP client supports, then confirm the connection by calling `roblox_bridge_status`.

## Available MCP tools

| Tool | Description |
|------|-------------|
| `roblox_bridge_status` | Check bridge status and whether the Studio plugin is connected |
| `roblox_get_selection` | Get currently selected instances in Studio |
| `roblox_list_children` | List children of an instance path |
| `roblox_get_properties` | Read properties from an instance |
| `roblox_set_property` | Set a property on an instance |
| `roblox_create_instance` | Create a new Roblox instance |
| `roblox_delete_instance` | Delete an instance |
| `roblox_get_script_source` | Read Script/LocalScript/ModuleScript source |
| `roblox_set_script_source` | Update script source |
| `roblox_run_code` | Execute Luau code in Studio |
| `roblox_find_instances` | Find instances by class/name pattern |

## Configuration

| Environment variable | Default | Description |
|----------------------|---------|-------------|
| `MINT_BRIDGE_PORT` | `5123` | Local HTTP bridge port used by the Studio plugin |
| `MINT_BRIDGE_HOST` | `127.0.0.1` | Local bridge bind host |

## Development

```bash
npm run dev        # Run server with tsx
npm run typecheck  # TypeScript type check
npm run build      # Compile to dist/
```

## GitHub Pages website

The static download/setup site lives in [`docs/`](./docs). Configure GitHub Pages to serve from the `docs/` folder on your default branch to publish it.

## Security

Mint is a local development tool. It can inspect and modify the currently open Roblox Studio place based on MCP tool calls. Only connect MCP clients you trust, and avoid using it on sensitive places without review.

## License

[MIT](./LICENSE)
