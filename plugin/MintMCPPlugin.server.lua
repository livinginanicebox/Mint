-- Mint MCP Bridge Plugin for Roblox Studio
-- Connects Roblox Studio to the local Mint MCP bridge so AI clients (Arena AI, etc.)
-- can inspect and modify the open place through MCP tools.

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local RunService = game:GetService("RunService")

local BRIDGE_URL = "http://127.0.0.1:5123"
local POLL_INTERVAL_IDLE = 0.5
local running = false
local pollThread: thread? = nil

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
local toolbar = plugin:CreateToolbar("Mint MCP")
local toggleButton = toolbar:CreateButton(
	"Mint MCP",
	"Connect/disconnect Mint MCP bridge",
	"rbxassetid://4483345998"
)
toggleButton.ClickableWhenViewportHidden = true

local function setButtonState(active: boolean)
	if active then
		toggleButton:SetActive(true)
	else
		toggleButton:SetActive(false)
	end
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function jsonEncode(value: any): string
	return HttpService:JSONEncode(value)
end

local function jsonDecode(value: string): any
	return HttpService:JSONDecode(value)
end

local function httpGet(url: string)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "GET",
			Headers = { ["Accept"] = "application/json" },
		})
	end)
	if not ok then
		return false, tostring(res)
	end
	return true, res
end

local function httpPost(url: string, body: table)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = jsonEncode(body),
		})
	end)
	if not ok then
		return false, tostring(res)
	end
	return true, res
end

local function getPath(path: string): Instance?
	if path == "game" or path == "game.DataModel" then
		return game
	end
	local parts = string.split(path, ".")
	local current: Instance = game
	local start = 1
	if parts[1] == "game" then
		start = 2
	end
	for i = start, #parts do
		local name = parts[i]
		if name == "" then
			continue
		end
		local child = current:FindFirstChild(name)
		if not child then
			-- Try common service lookup at root
			if current == game then
				local ok, svc = pcall(function()
					return game:GetService(name)
				end)
				if ok and svc then
					child = svc
				end
			end
		end
		if not child then
			return nil
		end
		current = child
	end
	return current
end

local function getFullPath(inst: Instance): string
	if inst == game then
		return "game"
	end
	local parts = {}
	local cur: Instance? = inst
	while cur and cur ~= game do
		table.insert(parts, 1, cur.Name)
		cur = cur.Parent
	end
	return "game." .. table.concat(parts, ".")
end

local function serializeValue(value: any): any
	local t = typeof(value)
	if t == "string" or t == "number" or t == "boolean" or value == nil then
		return value
	elseif t == "Vector3" then
		return { __type = "Vector3", x = value.X, y = value.Y, z = value.Z }
	elseif t == "Vector2" then
		return { __type = "Vector2", x = value.X, y = value.Y }
	elseif t == "Color3" then
		return { __type = "Color3", r = value.R, g = value.G, b = value.B }
	elseif t == "CFrame" then
		local comps = { value:GetComponents() }
		return { __type = "CFrame", components = comps }
	elseif t == "UDim2" then
		return { __type = "UDim2", xScale = value.X.Scale, xOffset = value.X.Offset, yScale = value.Y.Scale, yOffset = value.Y.Offset }
	elseif t == "UDim" then
		return { __type = "UDim", scale = value.Scale, offset = value.Offset }
	elseif t == "EnumItem" then
		return { __type = "EnumItem", enumType = tostring(value.EnumType), name = value.Name, value = value.Value }
	elseif t == "BrickColor" then
		return { __type = "BrickColor", name = value.Name, number = value.Number }
	elseif t == "Instance" then
		return { __type = "Instance", path = getFullPath(value), className = value.ClassName, name = value.Name }
	else
		return { __type = t, string = tostring(value) }
	end
end

local function parseValue(raw: any): any
	if type(raw) == "table" and raw.__type then
		local t = raw.__type
		if t == "Vector3" then
			return Vector3.new(raw.x or 0, raw.y or 0, raw.z or 0)
		elseif t == "Vector2" then
			return Vector2.new(raw.x or 0, raw.y or 0)
		elseif t == "Color3" then
			return Color3.new(raw.r or 0, raw.g or 0, raw.b or 0)
		elseif t == "UDim2" then
			return UDim2.new(raw.xScale or 0, raw.xOffset or 0, raw.yScale or 0, raw.yOffset or 0)
		elseif t == "UDim" then
			return UDim.new(raw.scale or 0, raw.offset or 0)
		elseif t == "BrickColor" then
			if raw.name then return BrickColor.new(raw.name) end
			if raw.number then return BrickColor.new(raw.number) end
		elseif t == "EnumItem" then
			-- raw.enumType like "Enum.Material", raw.name like "Plastic"
			local enumTypeName = tostring(raw.enumType):gsub("^Enum%.", "")
			local enumType = (Enum :: any)[enumTypeName]
			if enumType and raw.name then
				return enumType[raw.name]
			end
		end
		return raw
	end
	if type(raw) == "table" and #raw > 0 then
		-- Heuristic: arrays of 3 numbers are common for Vector3; callers should prefer typed objects.
		-- We leave arrays as-is unless a property setter handles them.
		return raw
	end
	return raw
end

local function setPropertyValue(inst: Instance, property: string, raw: any)
	local value = parseValue(raw)
	-- Special handling for common array forms
	if type(raw) == "table" and not raw.__type then
		local okProp, cur = pcall(function() return (inst :: any)[property] end)
		if okProp then
			local t = typeof(cur)
			if t == "Vector3" and #raw >= 3 then
				value = Vector3.new(tonumber(raw[1]) or 0, tonumber(raw[2]) or 0, tonumber(raw[3]) or 0)
			elseif t == "Color3" and #raw >= 3 then
				value = Color3.new(tonumber(raw[1]) or 0, tonumber(raw[2]) or 0, tonumber(raw[3]) or 0)
			elseif t == "Vector2" and #raw >= 2 then
				value = Vector2.new(tonumber(raw[1]) or 0, tonumber(raw[2]) or 0)
			elseif t == "UDim2" and #raw >= 4 then
				value = UDim2.new(tonumber(raw[1]) or 0, tonumber(raw[2]) or 0, tonumber(raw[3]) or 0, tonumber(raw[4]) or 0)
			end
		end
	end
	(inst :: any)[property] = value
end

local DEFAULT_PROPERTIES = {
	"Name", "ClassName", "Parent", "Archivable",
	"Anchored", "Transparency", "Position", "Size", "CFrame", "Color",
	"Material", "BrickColor", "CanCollide", "Visible", "Text", "Value",
	"Enabled", "Disabled", "Source",
}

local function describeInstance(inst: Instance, includeProps: {string}?): table
	local info: any = {
		name = inst.Name,
		className = inst.ClassName,
		path = getFullPath(inst),
	}
	local props = {}
	local wanted = includeProps or DEFAULT_PROPERTIES
	for _, prop in ipairs(wanted) do
		local ok, val = pcall(function()
			return (inst :: any)[prop]
		end)
		if ok then
			if prop == "Parent" then
				props[prop] = val and getFullPath(val) or nil
			elseif prop == "Source" then
				-- Don't inline full source in property dumps; indicate presence.
				props[prop] = string.format("<source:%d chars>", #tostring(val))
			else
				props[prop] = serializeValue(val)
			end
		end
	end
	info.properties = props
	return info
end

--------------------------------------------------------------------------------
-- Command handlers
--------------------------------------------------------------------------------
local handlers: {[string]: (params: any) -> any} = {}

handlers.get_selection = function(_params)
	local items = {}
	for _, inst in ipairs(Selection:Get()) do
		table.insert(items, {
			name = inst.Name,
			className = inst.ClassName,
			path = getFullPath(inst),
		})
	end
	return { selection = items }
end

handlers.list_children = function(params)
	local root = getPath(params.path or "game")
	if not root then
		error("Instance not found: " .. tostring(params.path))
	end
	local recursive = params.recursive == true
	local maxDepth = tonumber(params.maxDepth) or 2

	local function walk(inst: Instance, depth: number)
		local node: any = {
			name = inst.Name,
			className = inst.ClassName,
			path = getFullPath(inst),
		}
		if recursive and depth < maxDepth then
			local children = {}
			for _, child in ipairs(inst:GetChildren()) do
				table.insert(children, walk(child, depth + 1))
			end
			node.children = children
		else
			node.childCount = #inst:GetChildren()
		end
		return node
	end

	local children = {}
	for _, child in ipairs(root:GetChildren()) do
		table.insert(children, walk(child, 0))
	end
	return { path = getFullPath(root), children = children }
end

handlers.get_properties = function(params)
	local inst = getPath(params.path)
	if not inst then
		error("Instance not found: " .. tostring(params.path))
	end
	local props = params.properties
	if type(props) == "table" then
		return describeInstance(inst, props)
	end
	return describeInstance(inst, nil)
end

handlers.set_property = function(params)
	local inst = getPath(params.path)
	if not inst then
		error("Instance not found: " .. tostring(params.path))
	end
	local property = tostring(params.property)
	local recording = ChangeHistoryService:TryBeginRecording("Mint: Set " .. property)
	setPropertyValue(inst, property, params.value)
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	return { ok = true, path = getFullPath(inst), property = property, value = serializeValue((inst :: any)[property]) }
end

handlers.create_instance = function(params)
	local className = tostring(params.className)
	local parent = getPath(params.parentPath)
	if not parent then
		error("Parent not found: " .. tostring(params.parentPath))
	end
	local recording = ChangeHistoryService:TryBeginRecording("Mint: Create " .. className)
	local inst = Instance.new(className)
	if params.name then
		inst.Name = tostring(params.name)
	end
	if type(params.properties) == "table" then
		for k, v in pairs(params.properties) do
			pcall(function()
				setPropertyValue(inst, tostring(k), v)
			end)
		end
	end
	inst.Parent = parent
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	return { ok = true, path = getFullPath(inst), className = inst.ClassName, name = inst.Name }
end

handlers.delete_instance = function(params)
	local inst = getPath(params.path)
	if not inst then
		error("Instance not found: " .. tostring(params.path))
	end
	if inst == game then
		error("Cannot delete game")
	end
	local path = getFullPath(inst)
	local recording = ChangeHistoryService:TryBeginRecording("Mint: Delete " .. inst.Name)
	inst.Parent = nil
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	return { ok = true, deleted = path }
end

handlers.get_script_source = function(params)
	local inst = getPath(params.path)
	if not inst then
		error("Instance not found: " .. tostring(params.path))
	end
	if not inst:IsA("LuaSourceContainer") then
		error("Instance is not a script: " .. inst.ClassName)
	end
	local ok, source = pcall(function()
		return ScriptEditorService:GetEditorSource(inst :: LuaSourceContainer)
	end)
	if not ok then
		source = (inst :: any).Source
	end
	return { path = getFullPath(inst), className = inst.ClassName, source = source }
end

handlers.set_script_source = function(params)
	local inst = getPath(params.path)
	if not inst then
		error("Instance not found: " .. tostring(params.path))
	end
	if not inst:IsA("LuaSourceContainer") then
		error("Instance is not a script: " .. inst.ClassName)
	end
	local source = tostring(params.source or "")
	local recording = ChangeHistoryService:TryBeginRecording("Mint: Set Script Source")
	local ok, err = pcall(function()
		ScriptEditorService:UpdateSourceAsync(inst :: LuaSourceContainer, function(_old)
			return source
		end)
	end)
	if not ok then
		-- Fallback for older environments
		(inst :: any).Source = source
	end
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	return { ok = true, path = getFullPath(inst), length = #source }
end

handlers.run_code = function(params)
	local code = tostring(params.code or "")
	local logs: {string} = {}

	local fn, loadErr = loadstring(code)
	if not fn then
		return { ok = false, error = "Load error: " .. tostring(loadErr), logs = logs }
	end

	local env = setmetatable({
		print = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				parts[#parts + 1] = tostring(select(i, ...))
			end
			table.insert(logs, table.concat(parts, "\t"))
		end,
		warn = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				parts[#parts + 1] = tostring(select(i, ...))
			end
			table.insert(logs, "[warn] " .. table.concat(parts, "\t"))
		end,
	}, { __index = getfenv() })

	-- luau/loadstring env handling: setfenv is available in Roblox Lua
	pcall(function() setfenv(fn, env) end)

	local ok, result = pcall(fn)
	if not ok then
		return { ok = false, error = tostring(result), logs = logs }
	end

	local serialized = nil
	pcall(function() serialized = serializeValue(result) end)
	return { ok = true, result = serialized, logs = logs }
end

handlers.find_instances = function(params)
	local root = getPath(params.rootPath or "game")
	if not root then
		error("Root not found: " .. tostring(params.rootPath))
	end
	local className = params.className and tostring(params.className) or nil
	local namePattern = params.namePattern and tostring(params.namePattern) or nil
	local maxResults = math.clamp(tonumber(params.maxResults) or 100, 1, 500)

	local results = {}
	local function visit(inst: Instance)
		if #results >= maxResults then return end
		local match = true
		if className and not inst:IsA(className) then
			match = false
		end
		if match and namePattern then
			local ok, m = pcall(function() return string.match(inst.Name, namePattern) ~= nil end)
			match = ok and m
		end
		if match then
			table.insert(results, {
				name = inst.Name,
				className = inst.ClassName,
				path = getFullPath(inst),
			})
		end
		for _, child in ipairs(inst:GetChildren()) do
			if #results >= maxResults then break end
			visit(child)
		end
	end

	-- If searching from game root, iterate services/children
	if root == game then
		for _, child in ipairs(game:GetChildren()) do
			if #results >= maxResults then break end
			visit(child)
		end
	else
		visit(root)
	end

	return { results = results, count = #results, truncated = #results >= maxResults }
end

--------------------------------------------------------------------------------
-- Poll loop
--------------------------------------------------------------------------------
local function handleCommand(command: any)
	local action = tostring(command.action)
	local params = command.params or {}
	local handler = handlers[action]
	if not handler then
		return { id = command.id, ok = false, error = "Unknown action: " .. action }
	end
	local ok, result = pcall(handler, params)
	if not ok then
		return { id = command.id, ok = false, error = tostring(result) }
	end
	return { id = command.id, ok = true, data = result }
end

local function pollLoop()
	while running do
		local ok, res = httpGet(BRIDGE_URL .. "/poll")
		if ok and res then
			if res.StatusCode == 200 and res.Body and res.Body ~= "" then
				local decodeOk, payload = pcall(jsonDecode, res.Body)
				if decodeOk and payload and payload.type == "command" and payload.command then
					local result = handleCommand(payload.command)
					httpPost(BRIDGE_URL .. "/result", result)
				end
			elseif res.StatusCode == 204 then
				-- no command, loop continues
			else
				task.wait(POLL_INTERVAL_IDLE)
			end
		else
			-- Bridge not reachable; back off
			task.wait(2)
		end
	end
end

local function startBridge()
	if running then return end
	running = true
	setButtonState(true)
	pollThread = task.spawn(pollLoop)
	print("[Mint MCP] Connected to bridge at " .. BRIDGE_URL)
end

local function stopBridge()
	running = false
	setButtonState(false)
	print("[Mint MCP] Disconnected")
end

toggleButton.Click:Connect(function()
	if running then
		stopBridge()
	else
		startBridge()
	end
end)

plugin.Unloading:Connect(function()
	stopBridge()
end)

print("[Mint MCP] Plugin loaded. Click the Mint MCP toolbar button to connect.")
