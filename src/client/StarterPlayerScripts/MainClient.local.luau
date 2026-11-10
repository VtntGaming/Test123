--!strict
--!native
-- Discovers controllers and completes declared prerequisites before ordinary concurrent startup.

--// Services
local Players = game:GetService("Players")

--// Modules
-- Dynamic discovery returns an unknown export until its lifecycle contract is checked.
local RequireModule: (ModuleScript) -> unknown = require

--// References
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts")
local Controllers = PlayerScripts:WaitForChild("Controllers")
local LoadingUI = LocalPlayer.PlayerGui:WaitForChild("Loading")

--// Constants
local MAX_EXECUTION_TIME = 10

--// Types
type Entry = {
	Module: ModuleScript,
	Order: number?,
	Initialize: (() -> ())?,
	Loaded: boolean,
	Started: boolean,
	Completed: boolean,
}

--// Properties
local Entries: { Entry } = {}
local LoadedCount = 0

--// Functions
local function LoadController(entry: Entry): boolean
	local success, message = xpcall(function()
		local controller: unknown = RequireModule(entry.Module)
		assert(type(controller) == "table", "Controller must return a table")
		local initialize = (controller :: { [string]: unknown }).Init
		assert(type(initialize) == "function", "Controller must expose Init")
		entry.Initialize = initialize :: () -> ()
		return true
	end, debug.traceback)
	entry.Loaded = true
	LoadedCount += 1
	if not success then
		warn("Failed to load controller:", entry.Module.Name, message)
	end
	return success
end

local function InitializeController(entry: Entry): boolean
	local initialize = entry.Initialize
	if entry.Started or not initialize then
		return false
	end
	entry.Started = true
	local success, message = xpcall(function()
		initialize()
		return true
	end, debug.traceback)
	entry.Completed = true
	if not success then
		warn("Failed to initialize controller:", entry.Module.Name, message)
	end
	return success
end

local function Pending(initializing: boolean): (number, { string })
	local settled = 0
	local pending: { string } = {}
	for _, entry in Entries do
		local done = if initializing then entry.Completed or (entry.Loaded and not entry.Initialize) else entry.Loaded
		if done then
			settled += 1
		else
			table.insert(pending, entry.Module.Name)
		end
	end
	return settled, pending
end

local function DiscoverControllers()
	for _, module in Controllers:GetChildren() do
		if module:IsA("ModuleScript") and not module:GetAttribute("DISABLED") then
			table.insert(Entries, {
				Module = module,
				Order = module:GetAttribute("InitOrder") :: number?,
				Initialize = nil,
				Loaded = false,
				Started = false,
				Completed = false,
			})
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

local function LoadControllers()
	-- InitOrder is opt-in metadata: all declared prerequisites finish before ordinary modules load.
	for _, entry in Entries do
		if entry.Order ~= nil then
			if not LoadController(entry) or not InitializeController(entry) then
				error("Ordered controller startup failed: " .. entry.Module.Name)
			end
		else
			task.spawn(LoadController, entry)
		end
	end
	local start = os.clock()
	while LoadedCount < #Entries and os.clock() - start < MAX_EXECUTION_TIME do
		LoadingUI:SetAttribute("Progress", LoadedCount / math.max(#Entries, 1) * 0.5)
		task.wait()
	end
	LoadingUI:SetAttribute("Progress", 0.5)
	if LoadedCount < #Entries then
		local _, pending = Pending(false)
		warn("Controllers are taking too long to load:", pending)
	end
end

local function InitializeControllers()
	for _, entry in Entries do
		if not entry.Started and entry.Initialize then
			task.spawn(InitializeController, entry)
		end
	end
	local start = os.clock()
	local settled, pending = Pending(true)
	while settled < #Entries and os.clock() - start < MAX_EXECUTION_TIME do
		LoadingUI:SetAttribute("Progress", 0.5 + settled / math.max(#Entries, 1) * 0.5)
		task.wait()
		settled, pending = Pending(true)
	end
	if settled < #Entries then
		warn("Controllers are taking too long to initialize:", pending)
	end
	-- The loading screen owns its exit effect and destruction.
	LoadingUI:SetAttribute("Progress", 1)
	LoadingUI:SetAttribute("GameReady", true)
end

local function InitializeLateControllers()
	while true do
		local loading = false
		for _, entry in Entries do
			if not entry.Loaded then
				loading = true
			elseif not entry.Started and entry.Initialize then
				task.spawn(InitializeController, entry)
			end
		end
		if not loading then
			return
		end
		task.wait(MAX_EXECUTION_TIME)
	end
end

--// Bootstrap
if not game:IsLoaded() then
	game.Loaded:Wait()
end
DiscoverControllers()
LoadControllers()
InitializeControllers()
task.spawn(InitializeLateControllers)
