-- ==========================================
-- MAIN SERVER
-- ==========================================
local ServerScriptService = game:GetService("ServerScriptService")

-- ==========================================
-- VARIABLES
-- ==========================================
local Services = ServerScriptService:WaitForChild("Services")
local loadedServices = {}

-- ==========================================
-- FUNCTIONS
-- ==========================================
local function loadServices()
	for _, module in ipairs(Services:GetChildren()) do
		if module:IsA("ModuleScript") and not module:GetAttribute("DISABLED") then
			local service
			xpcall(function()
				service = require(module)
			end, function(err)
				warn("Failed to load service:", module.Name, "-", err)
			end)
			table.insert(loadedServices, service)
		end
	end
end

local function initializeServices()
	for _, service in ipairs(loadedServices) do
		if type(service.Init) == "function" then
			task.spawn(function()
				service.Init()
			end)
		end
	end
end

-- PlayerDataService owns its player connections and saves exactly once.
loadServices()
initializeServices()

print("hello Thien1")
print("hello Thien2")