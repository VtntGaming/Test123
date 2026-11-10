--!strict
-- Discovers services and completes declared prerequisites before ordinary concurrent initialization.

--// Services
local ServerScriptService = game:GetService("ServerScriptService")

--// Modules
-- Dynamic discovery returns an unknown export until its lifecycle contract is checked.
local RequireModule: (ModuleScript) -> unknown = require

--// References
local Services = ServerScriptService:WaitForChild("Services")

--// Types
type Entry = { Module: ModuleScript, Order: number?, Initialize: (() -> ())? }

--// Properties
local Entries: { Entry } = {}

--// Functions
local function LoadService(entry: Entry): boolean
	local success, message = xpcall(function()
		local service: unknown = RequireModule(entry.Module)
		assert(type(service) == "table", "Service must return a table")
		local initialize = (service :: { [string]: unknown }).Init
		if type(initialize) == "function" then
			entry.Initialize = initialize :: () -> ()
		end
		return true
	end, debug.traceback)
	if not success then
		warn("Failed to load service:", entry.Module.Name, message)
	end
	return success
end

local function InitializeService(entry: Entry): boolean
	local initialize = entry.Initialize
	if not initialize then
		return false
	end
	local success, message = xpcall(function()
		initialize()
		return true
	end, debug.traceback)
	if not success then
		warn("Failed to initialize service:", entry.Module.Name, message)
	end
	return success
end

local function DiscoverServices()
	for _, module in Services:GetChildren() do
		if module:IsA("ModuleScript") and not module:GetAttribute("DISABLED") then
			table.insert(
				Entries,
				{ Module = module, Order = module:GetAttribute("InitOrder") :: number?, Initialize = nil }
			)
		end
	end
	table.sort(Entries, function(a: Entry, b: Entry): boolean
		local aOrder, bOrder = a.Order or math.huge, b.Order or math.huge
		if aOrder == bOrder then
			return a.Module.Name < b.Module.Name
		end
		return aOrder < bOrder
	end)
end

local function LoadServices()
	for _, entry in Entries do
		local loaded = LoadService(entry)
		if entry.Order ~= nil then
			if not loaded or not InitializeService(entry) then
				error("Ordered service startup failed: " .. entry.Module.Name)
			end
		end
	end
end

local function InitializeServices()
	for _, entry in Entries do
		if entry.Order == nil and entry.Initialize then
			task.spawn(InitializeService, entry)
		end
	end
end

--// Bootstrap
DiscoverServices()
LoadServices()
InitializeServices()
