--!strict
--!native
-- ==========================================
-- MAIN CLIENT
-- ==========================================
local Players = game:GetService("Players")

-- ==========================================
-- VARIABLES
-- ==========================================
local LocalPlayer = Players.LocalPlayer :: Player
local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts")
local Controllers = PlayerScripts:WaitForChild("Controllers")
local LoadingUI = LocalPlayer.PlayerGui:WaitForChild("Loading")
local MAX_EXECUTION_TIME = 10
local TotalControllers = 0
local TotalCheckedControllers = 0
local loadedControllers = {}
local methods = {}
local processedMethods = {}

-- ==========================================
-- FUNCTIONS
-- ==========================================
local function loadControllers()
	local totalItems  = 0
	local loaded = 0
	local start = os.clock()

	local executing = {}

	for _, module in ipairs(Controllers:GetChildren()) do
		totalItems += 1
		table.insert(executing, module.Name)
		task.spawn(function()
			if module:IsA("ModuleScript") and not module:GetAttribute("DISABLED") then
				local controller
				TotalControllers += 1
				xpcall(function()
					controller = require(module) :: any
					local init = controller.Init
					assert(init, "Missing method .Init() for module ", module.Name)
					methods[module.Name] = init
				end, function(err)
					TotalCheckedControllers += 1
					warn("Failed to load controller:", module.Name, "-", err)
				end)
				table.insert(loadedControllers, controller)
			end
			
			table.remove(executing, table.find(executing, module.Name))
			loaded += 1
		end)
	end

	while loaded < totalItems and os.clock() - start < MAX_EXECUTION_TIME do
		LoadingUI:SetAttribute("Progress", (loaded / math.max(totalItems, 1)) * 0.5)
		task.wait()
	end
	LoadingUI:SetAttribute("Progress", 0.5)

	if loaded < totalItems then
		warn(`These module is taking too long to load!`, executing)
	end
end

local function fallbackInitialize()
	while TotalCheckedControllers < TotalControllers do
		task.wait(10)
		local fallbackCount = 0
		for name, callback in pairs(methods) do
			if table.find(processedMethods, callback) then
				continue
			end
			table.insert(processedMethods, callback)
			task.spawn(function()
				fallbackCount += 1
				TotalCheckedControllers += 1
				xpcall(callback, function(err) 
					warn(err)
				end)
			end)
		end

		if fallbackCount > 0 then
			warn(`Fallback processing for {fallbackCount} modules.`)
		end
	end
end

local function initializeControllers()
	-- for _, controller in ipairs(loadedControllers) do
	-- 	if type(controller.Init) == "function" then
 	-- 		task.spawn(function()
	-- 			controller.Init()
	-- 		end)
	-- 	end
	-- end

	local total = 0
	local loaded = 0
	local start = os.clock()
	local onQueue = {}

	for name, callback in pairs(methods) do
		total += 1
		TotalCheckedControllers += 1
		table.insert(onQueue, name)
		table.insert(processedMethods, callback)
		task.spawn(function()
			xpcall(callback, function(err) 
				warn(err)
			end)
			loaded += 1
			table.remove(onQueue, table.find(onQueue, name))
		end)
	end

	while loaded < total and os.clock() - start < MAX_EXECUTION_TIME do
		LoadingUI:SetAttribute("Progress", 0.5 + (loaded / math.max(total, 1)) * 0.5)
		task.wait()
	end

	if loaded < total then
		warn(`These module is taking too long to start! `, onQueue)
	end

	-- Tell ReplicatedFirst.LoadingScript we're done. It fills the bar, plays the exit
	-- effect and destroys the Loading UI itself.
	LoadingUI:SetAttribute("Progress", 1)
	LoadingUI:SetAttribute("GameReady", true)
end

-- ==========================================
-- BOOTSTRAP
-- ==========================================

if not game:IsLoaded() then
	game.Loaded:Wait()
end

loadControllers()
initializeControllers()
fallbackInitialize()