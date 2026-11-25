import { z } from "zod";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { RobloxBridge } from "./bridge.js";

function textResult(data: unknown) {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text }] };
}

function errorResult(message: string) {
  return { content: [{ type: "text" as const, text: message }], isError: true };
}

async function runBridgeCommand(
  bridge: RobloxBridge,
  action: string,
  params: Record<string, unknown> = {},
) {
  const result = await bridge.sendCommand(action, params);
  if (!result.ok) {
    return errorResult(result.error ?? `Command "${action}" failed`);
  }
  return textResult(result.data ?? { ok: true });
}

export function registerTools(server: McpServer, bridge: RobloxBridge): void {
  server.tool(
    "roblox_bridge_status",
    "Check whether the Mint bridge is running and whether the Roblox Studio plugin is connected.",
    {},
    async () => textResult(bridge.status),
  );

  server.tool(
    "roblox_get_selection",
    "Get the currently selected instances in Roblox Studio.",
    {},
    async () => runBridgeCommand(bridge, "get_selection"),
  );

  server.tool(
    "roblox_list_children",
    "List the children of an instance in the Roblox Studio data model.",
    {
      path: z
        .string()
        .describe(
          'Dot path from game, e.g. "game.Workspace", "game.ReplicatedStorage.MyFolder". Use "game" for top-level services.',
        ),
      recursive: z.boolean().optional().describe("If true, include descendants recursively."),
      maxDepth: z.number().int().min(0).max(20).optional().describe("Max recursion depth when recursive=true. Default 2."),
    },
    async ({ path, recursive, maxDepth }) =>
      runBridgeCommand(bridge, "list_children", { path, recursive: recursive ?? false, maxDepth: maxDepth ?? 2 }),
  );

  server.tool(
    "roblox_get_properties",
    "Get properties of a Roblox instance.",
    {
      path: z.string().describe('Dot path from game, e.g. "game.Workspace.Part".'),
      properties: z
        .array(z.string())
        .optional()
        .describe("Optional property names to read. If omitted, returns a default useful set."),
    },
    async ({ path, properties }) => runBridgeCommand(bridge, "get_properties", { path, properties }),
  );

  server.tool(
    "roblox_set_property",
    "Set a property on a Roblox instance.",
    {
      path: z.string().describe('Dot path from game, e.g. "game.Workspace.Part".'),
      property: z.string().describe("Property name, e.g. Name, Anchored, Transparency."),
      value: z
        .union([z.string(), z.number(), z.boolean(), z.null(), z.array(z.number())])
        .describe(
          "New value. For Vector3/Color3/CFrame-like values, pass an array of numbers as documented by the plugin (e.g. [x,y,z]).",
        ),
    },
    async ({ path, property, value }) => runBridgeCommand(bridge, "set_property", { path, property, value }),
  );

  server.tool(
    "roblox_create_instance",
    "Create a new Roblox instance under a parent.",
    {
      className: z.string().describe('Roblox class name, e.g. "Part", "Folder", "Script", "LocalScript".'),
      parentPath: z.string().describe('Parent dot path from game, e.g. "game.Workspace".'),
      name: z.string().optional().describe("Optional instance name."),
      properties: z
        .record(z.union([z.string(), z.number(), z.boolean(), z.null(), z.array(z.number())]))
        .optional()
        .describe("Optional properties to set after creation."),
    },
    async ({ className, parentPath, name, properties }) =>
      runBridgeCommand(bridge, "create_instance", { className, parentPath, name, properties }),
  );

  server.tool(
    "roblox_delete_instance",
    "Delete a Roblox instance by path.",
    {
      path: z.string().describe('Dot path from game, e.g. "game.Workspace.OldPart".'),
    },
    async ({ path }) => runBridgeCommand(bridge, "delete_instance", { path }),
  );

  server.tool(
    "roblox_get_script_source",
    "Read the source of a Script, LocalScript, or ModuleScript.",
    {
      path: z.string().describe('Dot path to the script instance, e.g. "game.ServerScriptService.Main".'),
    },
    async ({ path }) => runBridgeCommand(bridge, "get_script_source", { path }),
  );

  server.tool(
    "roblox_set_script_source",
    "Set the source of a Script, LocalScript, or ModuleScript. Creates undo waypoint in Studio when possible.",
    {
      path: z.string().describe('Dot path to the script instance, e.g. "game.ServerScriptService.Main".'),
      source: z.string().describe("The full new Luau source code for the script."),
    },
    async ({ path, source }) => runBridgeCommand(bridge, "set_script_source", { path, source }),
  );

  server.tool(
    "roblox_run_code",
    "Execute Luau code in Roblox Studio through the plugin. Use for inspection or making changes. Returns printed output and errors.",
    {
      code: z.string().describe("Luau code to execute in Roblox Studio."),
    },
    async ({ code }) => runBridgeCommand(bridge, "run_code", { code }),
  );

  server.tool(
    "roblox_find_instances",
    "Find instances by class name and/or name pattern under a root path.",
    {
      rootPath: z.string().optional().describe('Root path to search. Defaults to "game".'),
      className: z.string().optional().describe("Optional Roblox class name filter."),
      namePattern: z.string().optional().describe("Optional Lua pattern matched against instance Name."),
      maxResults: z.number().int().min(1).max(500).optional().describe("Max results. Default 100."),
    },
    async ({ rootPath, className, namePattern, maxResults }) =>
      runBridgeCommand(bridge, "find_instances", {
        rootPath: rootPath ?? "game",
        className,
        namePattern,
        maxResults: maxResults ?? 100,
      }),
  );
}
