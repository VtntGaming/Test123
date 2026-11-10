-- Schedules shared physical shrinking; clients render the same synchronized surface.
local ArenaShrinkService = {}

-- ==========================================
-- SERVICES & MODULES
-- ==========================================
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local GameConfig = require(SharedModules:WaitForChild("GameConfig"))
local ArenaSimulation = require(ReplicatedStorage.Simulation.Arena)

-- ==========================================
-- VARIABLES
-- ==========================================
local Events = ReplicatedStorage:WaitForChild("Events")
local ShrinkEvent = Events:FindFirstChild("ShrinkEvent") or Instance.new("RemoteEvent", Events)
ShrinkEvent.Name = "ShrinkEvent"

local isShrinking = false
local revision = 0
local visualTarget = nil

local function restoreVisuals()
	if visualTarget then
		ArenaSimulation.Clear(visualTarget)
	end
	visualTarget = nil
end

-- ==========================================
-- INTERNAL FUNCTIONS
-- ==========================================
local function executeShrink(targetModel, token, clientVisuals)
	if not isShrinking or revision ~= token then
		return
	end
	local duration = GameConfig.MatchTimeLimit - GameConfig.ArenaShrink.InitialDelay
	visualTarget = targetModel
	ArenaSimulation.RegisterScale(targetModel, time(), duration, GameConfig.ArenaShrink.MinScale)
	ShrinkEvent:FireAllClients("Start")
	task.delay(duration, function()
		if isShrinking and revision == token and targetModel.Parent then
			targetModel:Destroy()
		end
	end)
end

-- ==========================================
-- PUBLIC API
-- ==========================================
function ArenaShrinkService.Start()
	restoreVisuals()
	revision += 1
	local token = revision
	isShrinking = true
	
	task.delay(GameConfig.ArenaShrink.InitialDelay, function()
		if not isShrinking or revision ~= token then return end
		
		local currentArena = CollectionService:GetTagged("DestroyableArena")[1]
		if not currentArena then return end

		local blocksContainer = currentArena:FindFirstChild("Blocks") or currentArena:FindFirstChild("Block") or currentArena:FindFirstChild("Main")
		local targetModel = blocksContainer and (blocksContainer:IsA("Model") and blocksContainer or blocksContainer:FindFirstChildWhichIsA("Model"))
		
		if targetModel and targetModel.PrimaryPart then
			executeShrink(targetModel, token, currentArena:GetAttribute("ArenaEffectModule") == "Moon")
		end
	end)
end

function ArenaShrinkService.Stop()
	revision += 1
	isShrinking = false
	restoreVisuals()
	ShrinkEvent:FireAllClients("Stop")
end

function ArenaShrinkService.Init()
end

return ArenaShrinkService
