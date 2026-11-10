local ArenaDestructionService = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local GameConfig = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("GameConfig"))
local ArenaPlatformOrder = require(script.Parent.Helper.ArenaPlatformOrder)

-- ==========================================
-- VARIABLES
-- ==========================================
local Events = ReplicatedStorage:WaitForChild("Events")
local DestructionEvent = Events:WaitForChild("DestructionEvent")

local DESTRUCTION_ORDER = { "Group A", "Group B", "Group C", "Group D", "Center" }
local isDestructionActive = false
local revision = 0

-- ==========================================
-- INTERNAL FUNCTIONS
-- ==========================================
local function valid(token: number, model: Model)
	return isDestructionActive and token == revision and model:IsDescendantOf(workspace)
end

local function destroyModel(model: Model, token: number)
	if not valid(token, model) then
		return
	end

	DestructionEvent:FireAllClients("Warning", model)
	task.wait(GameConfig.ArenaDestruction.WarningDuration)

	if not valid(token, model) then
		return
	end

	DestructionEvent:FireAllClients("Destroy", model)

	for _, ins in ipairs(model:GetDescendants()) do
		if ins:IsA("BasePart") then
			ins.CanCollide = false
		end
	end
	task.delay(2.5, function()
		model:Destroy()
	end)
end

local function destructionRoutine(token: number)
	task.wait(GameConfig.ArenaDestruction.InitialDelay)
	if not isDestructionActive or token ~= revision then
		return
	end

	local currentArena = CollectionService:GetTagged("DestroyableArena")[1]
	if not currentArena then
		return
	end

	local blocksFolder = currentArena:FindFirstChild("Blocks")
	if not blocksFolder then
		return
	end

	local platforms = {}
	local centerPlatforms = {}
	for _, groupName in DESTRUCTION_ORDER do
		local groupFolder = blocksFolder:FindFirstChild(groupName)

		if groupFolder then
			for _, model in groupFolder:GetChildren() do
				if model:IsA("Model") then
					table.insert(platforms, model)
					centerPlatforms[model] = groupName == "Center"
				end
			end
		end
	end
	local ordered, spawnPlatform = ArenaPlatformOrder.SpawnLast(currentArena, platforms)
	for _, model in ordered do
		if not valid(token, model) then
			return
		end
		if centerPlatforms[model] or model == spawnPlatform then
			task.wait(GameConfig.ArenaDestruction.IntervalLastBlock)
		end
		if not valid(token, model) then
			return
		end
		destroyModel(model, token)
		if not centerPlatforms[model] and model ~= spawnPlatform then
			task.wait(GameConfig.ArenaDestruction.IntervalBetweenBlocks)
		end
	end
end

-- ==========================================
-- PUBLIC API
-- ==========================================
function ArenaDestructionService.Start()
	revision += 1
	isDestructionActive = true
	task.spawn(destructionRoutine, revision)
end

function ArenaDestructionService.Stop()
	isDestructionActive = false
	revision += 1
end

function ArenaDestructionService.Init() end

return ArenaDestructionService
